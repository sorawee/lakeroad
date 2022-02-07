use std::{
    collections::{HashMap, HashSet},
    fmt::Display,
    io::Write,
    process::{Command, Stdio},
    str::FromStr,
};

use crate::language::LanguageAnalysisData::*;
use egg::{
    define_language, rewrite, Analysis, Applier, AstSize, DidMerge, EGraph, Extractor, Id,
    Language as LanguageTrait, Pattern, RecExpr, Rewrite, Searcher, Var,
};
use rayon::prelude::*;

define_language! {
    /// Expressions (Exprs) in our language can be constructed two ways: first,
    /// by directly constructing an expression by combining `var`s and `const`s
    /// with `unop` and `binop` operator applications. They can also be
    /// indirectly constructed by `apply`ing instructions onto arguments, which
    /// are themselves expressions. The intention behind having these two
    /// methods is so that we can ingest programs in the first form (which is
    /// easy to compile to or to write by hand) and then rewrite to the second
    /// form, which is harder to write but is useful for enumerating the space
    /// of possible instructions in the ISA.
    pub enum Language {

        // (var name: String bitwidth: Num) -> Expr
        "var" = Var([Id; 2]),

        // (const val: Num bitwidth: Num) -> Expr
        "const" = Const([Id; 2]),

        // Operator application. When applied to an expression, returns an
        // expression; when applied to an AST, returns an AST.
        //
        // (unop op: Op bitwidth: Num arg: Expr or AST) -> Expr or AST
        "unop" = UnOp([Id; 3]),
        // (binop op: Op bitwidth: Num arg0,arg1: Expr or AST) -> Expr or AST
        "binop" = BinOp([Id; 4]),

        // (apply instr: Instr args: List of Exprs) -> Expr
        "apply" = Apply([Id; 2]),

        // Hole.
        // (hole bitwidth: Num) -> AST
        "hole" = Hole([Id; 1]),

        "list" = List(Box<[Id]>),

        // (concat l0: List l1: List) -> List
        "concat" = Concat([Id;2]),

        // Canonicalizes a list of args.
        // (canonicalize (list args...: Expr))
        //   gets rewritten to (canonical-args ids...: Num)
        "canonicalize" = Canonicalize([Id; 1]),

        // Canonical args are simply a list of natural numbers, starting with 0
        // and increasing by 1 (but allowing repetitions of previously-seen
        // numbers.)
        // Canonical args are paired with an AST to construct an instruction.
        "canonical-args" = CanonicalArgs(Box<[Id]>),

        // (instr ast: AST canonical-args: List) -> Instr
        // An instruction.
        // For example, the instruction
        // (instr (binop and 8 (hole 8) (hole 8)) (canonical-args 0 1))
        // represents an AND instruction whose two holes are filled with two
        // different variables, e.g. (and x y), while
        // (instr (binop and 8 (hole 8) (hole 8)) (canonical-args 0 0))
        // represents an AND instruction whose two holes are filled with the
        // same variable, e.g. (and x x).
        "instr" = Instr([Id; 2]),

        Op(Op),
        Num(i64),
        String(String),
    }
}

#[derive(PartialEq, Debug, Eq, PartialOrd, Ord, Hash, Clone)]
pub enum Op {
    And,
    Or,
    Not,
    Sub,
    Xor,
    Asr,
}
impl Display for Op {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Op::And => "and",
                Op::Or => "or",
                Op::Not => "not",
                Op::Sub => "sub",
                Op::Xor => "xor",
                Op::Asr => "asr",
            }
        )
    }
}
impl FromStr for Op {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "and" => Ok(Op::And),
            "or" => Ok(Op::Or),
            "not" => Ok(Op::Not),
            "sub" => Ok(Op::Sub),
            "xor" => Ok(Op::Xor),
            "asr" => Ok(Op::Asr),
            _ => Err(()),
        }
    }
}

#[derive(Default)]
pub struct LanguageAnalysis;
#[derive(Debug, Clone, PartialEq)]
pub enum LanguageAnalysisData {
    /// A function which takes the arguments represented by the vector and
    /// returns the type indicated by the second argument.
    Function {
        args: HashMap<String, usize>,
        ret: usize,
    },

    // Represents a signal with the given bitwidth.
    Signal(usize),
    _String(String),
    Num(i64),
    Op(Op),
    List(Box<[Id]>),
    /// An instruction. The usize represents its output bitwidth.
    Instr(usize),
    Empty,
}
impl Analysis<Language> for LanguageAnalysis {
    type Data = LanguageAnalysisData;

    fn make(egraph: &EGraph<Language, Self>, enode: &Language) -> Self::Data {
        match enode {
            &Language::Instr([ast_id, canonical_args_id]) => {
                match (&egraph[ast_id].data, &egraph[canonical_args_id].data) {
                    (Signal(v), Empty) => Instr(*v),
                    _ => panic!(),
                }
            }
            &Language::Canonicalize([list_id]) => match &egraph[list_id].data {
                List(_) => Empty,
                _ => panic!(),
            },
            Language::CanonicalArgs(ids) => {
                ids.iter().for_each(|v| match &egraph[*v].data {
                    Num(_) => (),
                    _ => panic!(),
                });
                Empty
            }
            Language::Var([.., bitwidth_id]) | Language::Const([.., bitwidth_id]) => {
                match &egraph[*bitwidth_id].data {
                    &Num(v) => {
                        assert!(v > 0, "expect bitwidths to be positive");
                        Signal(v as usize)
                    }
                    _ => panic!(),
                }
            }
            Language::Num(v) => Num(*v),
            Language::String(v) => _String(v.clone()),
            &Language::BinOp([op_id, bitwidth_id, a_id, b_id]) => {
                match (
                    &egraph[op_id].data,
                    &egraph[bitwidth_id].data,
                    &egraph[a_id].data,
                    &egraph[b_id].data,
                ) {
                    (Op(_), Num(bitwidth), Signal(a_bitwidth), Signal(b_bitwidth)) => {
                        assert_eq!(a_bitwidth, b_bitwidth, "bitwidths must match");
                        assert_eq!(*a_bitwidth, *bitwidth as usize, "bitwidths must match");
                        Signal(*bitwidth as usize)
                    }
                    _ => panic!("types don't check; is {:?} an op?", egraph[op_id]),
                }
            }
            &Language::UnOp([op_id, bitwidth_id, arg_id]) => {
                match (
                    &egraph[op_id].data,
                    &egraph[bitwidth_id].data,
                    &egraph[arg_id].data,
                ) {
                    (Op(_), Num(out_bitwidth), Signal(arg_bitwidth)) => {
                        assert_eq!(
                            *arg_bitwidth, *out_bitwidth as usize,
                            "bitwidths must match"
                        );
                        Signal(*out_bitwidth as usize)
                    }
                    _ => panic!("types don't check; is {:?} an op?", egraph[op_id]),
                }
            }
            Language::Op(op) => Op(op.clone()),
            &Language::Hole([bw_id]) => match &egraph[bw_id].data {
                Num(v) => Signal(*v as usize),
                _ => panic!(),
            },
            Language::List(ids) => List(ids.clone()),
            &Language::Concat([a_id, b_id]) => match (&egraph[a_id].data, &egraph[b_id].data) {
                (List(a), List(b)) => List(
                    a.iter()
                        .chain(b.iter())
                        .cloned()
                        .collect::<Vec<_>>()
                        .into_boxed_slice(),
                ),
                _ => panic!(),
            },
            &Language::Apply([instr_id, _args_id]) => match &egraph[instr_id].data {
                Instr(v) => Signal(*v),
                other @ _ => panic!("Expected instruction, found:\n{:#?}", other),
            },
        }
    }

    fn merge(&mut self, a: &mut Self::Data, b: Self::Data) -> egg::DidMerge {
        assert_eq!(*a, b);
        DidMerge(false, false)
    }
}

/// Returns the string representing the Racket expression, and a map mapping
/// symbol names to their bitwidths.
pub fn to_racket(expr: &RecExpr<Language>, id: Id) -> (Option<String>, HashMap<String, usize>) {
    let mut map = HashMap::default();
    let racket_string = to_racket_helper(expr, id, &mut map);
    (racket_string, map)
}

fn to_racket_helper(
    expr: &RecExpr<Language>,
    id: Id,
    map: &mut HashMap<String, usize>,
) -> Option<String> {
    match expr[id] {
        Language::Var([name_id, bw_id]) => match (&expr[name_id], &expr[bw_id]) {
            (Language::String(v), Language::Num(bw)) => {
                map.insert(v.clone(), (*bw).try_into().unwrap());
                Some(v.clone())
            }
            _ => panic!(),
        },
        Language::Const([val_id, bitwidth_id]) => Some(format!(
            "(bv {val} {bitwidth})",
            val = match &expr[val_id] {
                Language::Num(v) => v.clone(),
                _ => panic!(),
            },
            bitwidth = match expr[bitwidth_id] {
                Language::Num(v) => v.clone(),
                _ => panic!(),
            },
        )),
        Language::Num(_) => None,
        Language::String(_) => None,
        Language::Apply(_) => todo!(),
        Language::BinOp([op_id, _bw_id, a_id, b_id]) => Some(format!(
            "({op} {a} {b})",
            op = match &expr[op_id] {
                Language::Op(op) => match op {
                    Op::And => "bvand",
                    Op::Or => "bvor",
                    Op::Sub => "bvsub",
                    Op::Xor => "bvxor",
                    Op::Asr => "bvashr",
                    _ => panic!(),
                },
                _ => panic!(),
            },
            a = to_racket_helper(expr, a_id, map).unwrap(),
            b = to_racket_helper(expr, b_id, map).unwrap()
        )),
        Language::UnOp([op_id, _bw_id, arg_id]) => Some(format!(
            "({op} {a})",
            op = match &expr[op_id] {
                Language::Op(op) => match op {
                    Op::Not => "bvnot",
                    _ => panic!(),
                },
                _ => panic!(),
            },
            a = to_racket_helper(expr, arg_id, map).unwrap(),
        )),
        Language::Hole(_) => todo!(),
        Language::List(_) => todo!(),
        Language::Concat(_) => todo!(),
        Language::Op(_) => todo!(),
        Language::CanonicalArgs(_) | Language::Canonicalize(_) | Language::Instr(_) => panic!(),
    }
}

pub fn call_racket(expr: String, map: &HashMap<String, usize>) -> bool {
    let full_expr = format!(
        "
    (begin
        {defines}
        (define (f {args}) {expr})
        f)",
        defines = map
            .iter()
            .map(|(k, v)| { format!("(define-symbolic {} (bitvector {}))", k, v) })
            .collect::<Vec<_>>()
            .join("\n"),
        args = map
            .keys()
            .into_iter()
            .cloned()
            .collect::<Vec<_>>()
            .join(" "),
        expr = expr,
    );

    let mut cmd = Command::new("racket");
    cmd.arg("-tm");
    cmd.arg("../racket/test.rkt");
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let mut proc = cmd.spawn().ok().expect("Failed to spawn process");
    proc.stdin
        .as_mut()
        .unwrap()
        .write_all(full_expr.as_bytes())
        .unwrap();
    let output = proc.wait_with_output().unwrap();

    output.status.success()
}

pub fn introduce_hole_var() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("introduce-hole-var";
                "(var ?a ?bw)" =>
                "(apply (instr (hole ?bw) (canonicalize (list (var ?a ?bw)))) (list (var ?a ?bw)))")
}

// This shouldn't be called fusion. Or, more specifically, the next two rewrites
// are also fusion in different forms. So only labeling this rewrite as fusion
// is misleading.
pub fn fuse_op() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("fuse-op";
                "(binop ?op ?bw
                  (apply (instr ?ast0 ?canonical-args0) ?args0)
                  (apply (instr ?ast1 ?canonical-args1) ?args1))" => 
                "(apply
                  (instr (binop ?op ?bw ?ast0 ?ast1) (canonicalize (concat ?args0 ?args1)))
                  (concat ?args0 ?args1))")
}

pub fn introduce_hole_op_left() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("introduce-hole-op-left";
                "(binop ?op ?bw
                  (apply (instr ?ast0 ?canonical-args0) ?args0)
                  (apply (instr ?ast1 ?canonical-args1) ?args1))" => 
                "(apply 
                  (instr
                   (binop ?op ?bw (hole ?bw) ?ast1)
                   (canonicalize (concat (list (apply (instr ?ast0 ?canonical-args0) ?args0)) ?args1)))
                  (concat (list (apply (instr ?ast0 ?canonical-args0) ?args0)) ?args1))")
}

pub fn introduce_hole_op_right() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("introduce-hole-op-right";
                "(binop ?op ?bw
                  (apply (instr ?ast0 ?canonical-args0) ?args0)
                  (apply (instr ?ast1 ?canonical-args1) ?args1))" => 
                "(apply 
                  (instr
                   (binop ?op ?bw ?ast0 (hole ?bw))
                   (canonicalize (concat ?args0 (list (apply (instr ?ast1 ?canonical-args1) ?args1)))))
                  (concat ?args0 (list (apply (instr ?ast1 ?canonical-args1) ?args1))))")
}

pub fn introduce_hole_op_both() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("introduce-hole-op-both";
                "(binop ?op ?bw
                  (apply (instr ?ast0 ?canonical-args0) ?args0)
                  (apply (instr ?ast1 ?canonical-args1) ?args1))" => 
                "(apply 
                  (instr
                   (binop ?op ?bw (hole ?bw) (hole ?bw))
                   (canonicalize
                    (list
                     (apply (instr ?ast0 ?canonical-args0) ?args0)
                     (apply (instr ?ast1 ?canonical-args1) ?args1))))
                  (list
                   (apply (instr ?ast0 ?canonical-args0) ?args0)
                   (apply (instr ?ast1 ?canonical-args1) ?args1)))")
}

pub fn unary0() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("unary0";
                "(unop ?op ?bw (apply (instr ?ast ?canonical-args) ?args))" => 
                "(apply (instr (unop ?op ?bw ?ast) (canonicalize ?args)) ?args)")
}

pub fn unary1() -> Rewrite<Language, LanguageAnalysis> {
    rewrite!("unary1";
                "(unop ?op ?bw (apply (instr ?ast ?canonical-args) ?args))" => 
                "(apply
                  (instr (unop ?op ?bw (hole ?bw)) (canonicalize (list (apply (instr ?ast ?canonical-args) ?args))))
                  (list (apply (instr ?ast ?canonical-args) ?args)))")
}

pub fn canonicalize() -> Rewrite<Language, LanguageAnalysis> {
    struct Impl(Var);
    impl Applier<Language, LanguageAnalysis> for Impl {
        fn apply_one(
            &self,
            egraph: &mut EGraph<Language, LanguageAnalysis>,
            eclass: Id,
            subst: &egg::Subst,
            _searcher_ast: Option<&egg::PatternAst<Language>>,
            _rule_name: egg::Symbol,
        ) -> Vec<Id> {
            let ids = match &egraph[subst[self.0]].data {
                List(v) => v.clone(),
                _ => panic!(),
            };

            let mut next = 0;
            let mut map = HashMap::new();
            for id in ids.iter() {
                if !map.contains_key(id) {
                    map.insert(id, next);
                    next += 1;
                }
            }

            let new_list = ids
                .iter()
                .cloned()
                .map(|id| egraph.add(crate::language::Language::Num(*map.get(&id).unwrap())))
                .collect::<Vec<_>>();

            let canonical_args_id = egraph.add(crate::language::Language::CanonicalArgs(
                new_list.into_boxed_slice(),
            ));

            egraph.union(eclass, canonical_args_id);

            vec![eclass, canonical_args_id]
        }
    }

    rewrite!("canonicalize";
                "(canonicalize ?list)" => { Impl("?list".parse().unwrap()) })
}

fn extract_ast(
    egraph: &EGraph<Language, LanguageAnalysis>,
    ast_id: Id,
    canonical_args_id: Id,
) -> RecExpr<Language> {
    let mut expr = RecExpr::default();
    let mut canonical_args = egraph[canonical_args_id]
        .iter()
        .find(|l| match l {
            crate::language::Language::CanonicalArgs(_) => true,
            _ => false,
        })
        .unwrap()
        .children()
        .iter()
        .map(|id| match &egraph[*id].data {
            Num(v) => usize::try_from(*v).unwrap(),
            _ => panic!(),
        })
        .collect::<Vec<_>>();
    extract_ast_helper(egraph, ast_id, &mut expr, &mut canonical_args);
    expr
}

/// args: a mutable list of the args to be swapped in for each hole, in
/// sequential order, assuming we traverse to the holes depth-first,
/// left-to-right.
fn extract_ast_helper(
    egraph: &EGraph<Language, LanguageAnalysis>,
    id: Id,
    expr: &mut RecExpr<Language>,
    args: &mut Vec<usize>,
) -> Id {
    match {
        assert_eq!(egraph[id].nodes.len(), 1);
        &egraph[id].nodes[0]
    } {
        Language::Op(op) => expr.add(Language::Op(op.clone())),
        &Language::BinOp([op_id, bw_id, a_id, b_id]) => {
            let new_op_id = extract_ast_helper(egraph, op_id, expr, args);
            let new_bw_id = extract_ast_helper(egraph, bw_id, expr, args);
            let new_a_id = extract_ast_helper(egraph, a_id, expr, args);
            let new_b_id = extract_ast_helper(egraph, b_id, expr, args);
            expr.add(Language::BinOp([new_op_id, new_bw_id, new_a_id, new_b_id]))
        }
        &Language::UnOp([op_id, bw_id, arg_id]) => {
            let new_op_id = extract_ast_helper(egraph, op_id, expr, args);
            let new_bw_id = extract_ast_helper(egraph, bw_id, expr, args);
            let new_arg_id = extract_ast_helper(egraph, arg_id, expr, args);
            expr.add(Language::UnOp([new_op_id, new_bw_id, new_arg_id]))
        }
        &Language::Hole([bw_id]) => {
            let new_bw_id = extract_ast_helper(egraph, bw_id, expr, args);
            assert!(!args.is_empty());
            let arg_id = args.remove(0);
            let name = format!("var{}", arg_id);
            let name_id = expr.add(Language::String(name));
            expr.add(Language::Var([name_id, new_bw_id]))
        }
        &Language::Num(v) => expr.add(Language::Num(v)),
        _ => panic!(),
    }
}

pub fn find_isa_instructions(
    egraph: &EGraph<Language, LanguageAnalysis>,
) -> Vec<(Id, RecExpr<Language>)> {
    let mut out = Vec::default();
    let ast_var: Var = "?ast".parse().unwrap();
    let canonical_args_var: Var = "?canonical-args".parse().unwrap();
    for search_match in format!(
        "(instr {} {})",
        ast_var.to_string(),
        canonical_args_var.to_string()
    )
    .parse::<Pattern<_>>()
    .unwrap()
    .search(egraph)
    {
        // I'm not sure if either of these will always be true. For now it's
        // simpler to assume they are true and then deal with it when they're
        // not. Basically, we're assuming that every (instr ?ast ?args) instance
        // is unique. If these fail, it probably means that instructions were
        // proven to be equivalent, which is actually cool and good but I just
        // haven't thought about what to do in that case. Do we just take one
        // instruction? Whatever we do, we'll need to make a more informed
        // decision.
        assert_eq!(search_match.substs.len(), 1);
        assert_eq!(egraph[search_match.eclass].nodes.len(), 1);
        for subst in search_match.substs {
            let ast_id = subst[ast_var];
            let canonical_args_id = subst[canonical_args_var];
            out.push((
                search_match.eclass,
                extract_ast(egraph, ast_id, canonical_args_id),
            ));
        }
    }

    out
}

pub fn simplify_concat() -> Rewrite<Language, LanguageAnalysis> {
    struct Impl {
        list0: Var,
        list1: Var,
    }
    impl Applier<Language, LanguageAnalysis> for Impl {
        fn apply_one(
            &self,
            egraph: &mut EGraph<Language, LanguageAnalysis>,
            eclass: Id,
            subst: &egg::Subst,
            _searcher_ast: Option<&egg::PatternAst<Language>>,
            _rule_name: egg::Symbol,
        ) -> Vec<Id> {
            let (ids0, ids1) = match (
                &egraph[subst[self.list0]].data,
                &egraph[subst[self.list1]].data,
            ) {
                (List(ids0), List(ids1)) => (ids0.clone(), ids1.clone()),
                _ => panic!(),
            };
            let new_list_id = egraph.add(Language::List([ids0, ids1].concat().into_boxed_slice()));
            egraph.union(eclass, new_list_id);

            vec![eclass, new_list_id]
        }
    }
    let list0: Var = "?list0".parse().unwrap();
    let list1: Var = "?list1".parse().unwrap();
    rewrite!("simplify-concat";
                { format!("(concat {} {})", list0.to_string(), list1.to_string()).parse::<Pattern<_>>().unwrap() }
                =>
                { Impl { list0, list1}})
}

pub fn explore_new(egraph: &EGraph<Language, LanguageAnalysis>, _id: Id) -> HashMap<Id, bool> {
    let extractor = Extractor::new(egraph, AstSize);
    let out: HashMap<Id, bool> = egraph
        .classes()
        .par_bridge()
        .map(|eclass| {
            let (_, expr) = extractor.find_best(eclass.id);
            let (racket_expr, map) = to_racket(&expr, (expr.as_ref().len() - 1).into());
            if racket_expr.is_none() {
                println!("Not attempting to synthesize:\n{}", expr.pretty(80));
                (eclass.id, false)
            } else {
                println!("Attempting to synthesize:\n{}", expr.pretty(80),);
                let result = call_racket(racket_expr.unwrap(), &map);
                (eclass.id, result)
            }
        })
        .collect();

    println!("ISA:");
    for (k, v) in out.iter() {
        if *v {
            println!("{}", extractor.find_best(*k).1.pretty(80))
        }
    }

    out
}

pub fn instr_appears_in_program(
    egraph: &EGraph<Language, LanguageAnalysis>,
    instr_id: Id,
    program_root: Id,
) -> bool {
    let mut worklist: HashSet<Id> = HashSet::new();
    worklist.insert(program_root);
    let mut visited: HashSet<Id> = HashSet::new();

    while !worklist.is_empty() {
        // Get next Id and remove it from the worklist.
        let this = *worklist.iter().next().unwrap();
        assert!(worklist.remove(&this));
        assert!(visited.insert(this));

        if this == instr_id {
            return true;
        }

        for enode in &egraph[this].nodes {
            let ids = match enode {
                Language::Const(ids)
                | Language::Var(ids)
                | Language::Instr(ids)
                | Language::Concat(ids)
                | Language::Apply(ids) => ids.to_vec(),
                Language::UnOp(ids) => ids.to_vec(),
                Language::BinOp(ids) => ids.to_vec(),
                Language::Canonicalize(ids) | Language::Hole(ids) => ids.to_vec(),
                Language::CanonicalArgs(ids) | Language::List(ids) => ids.to_vec(),
                Language::Op(_) | Language::Num(_) | Language::String(_) => vec![],
            };

            worklist.extend(ids.iter().filter(|id| !visited.contains(id)));
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use egg::{RecExpr, Runner};

    use super::*;

    #[test]
    fn ceil_avg() {
        let mut egraph: EGraph<Language, LanguageAnalysis> = EGraph::default();

        let id = egraph.add_expr(
            &RecExpr::from_str(
            "(binop sub 8 (binop or 8 (var x 8) (var y 8)) (binop asr 8 (binop xor 8 (var x 8) (var y 8)) (const 1 8)))",
            )
            .unwrap(),
        );

        match &egraph[id].data {
            Signal(8) => (),
            _ => panic!(),
        }
    }

    #[test]
    fn ceil_avg_to_racket() {
        let expr = &RecExpr::from_str(
            "(binop sub 8 (binop or 8 (var x 8) (var y 8)) (binop asr 8 (binop xor 8 (var x 8) (var y 8)) (const 1 8)))",
        )
        .unwrap();

        let (expr, map) = to_racket(expr, (expr.as_ref().len() - 1).into());
        assert_eq!(*map.get("x").unwrap(), 8);
        assert_eq!(*map.get("y").unwrap(), 8);
        assert_eq!(
            expr.unwrap(),
            "(bvsub (bvor x y) (bvashr (bvxor x y) (bv 1 8)))"
        );
    }

    #[test]
    fn ceil_avg_to_racket_call_racket() {
        let expr = &RecExpr::from_str(
            "(binop sub 8 (binop or 8 (var x 8) (var y 8)) (binop asr 8 (binop xor 8 (var x 8) (var y 8)) (const 1 8)))",
        )
        .unwrap();

        let (expr, map) = to_racket(expr, (expr.as_ref().len() - 1).into());

        assert!(!call_racket(expr.unwrap(), &map));
    }

    #[test_log::test]
    fn rewrite_new() {
        let mut egraph: EGraph<Language, LanguageAnalysis> = EGraph::default();
        let _id = egraph.add_expr(
            &RecExpr::from_str(
                "
(binop and 8 (var a 8) (binop or 8 (var b 8) (var a 8)))
",
            )
            .unwrap(),
        );

        let runner = Runner::default().with_egraph(egraph).run(&vec![
            introduce_hole_var(),
            fuse_op(),
            introduce_hole_op_both(),
            introduce_hole_op_left(),
            introduce_hole_op_right(),
            unary0(),
            unary1(),
            simplify_concat(),
            canonicalize(),
        ]);

        let isa_instrs: Vec<_> = find_isa_instructions(&runner.egraph)
            .par_iter()
            .filter(|(_, expr)| {
                if let (Some(racket_str), map) = to_racket(&expr, (expr.as_ref().len() - 1).into())
                {
                    println!("Attempting: {}", racket_str);
                    call_racket(racket_str, &map)
                } else {
                    false
                }
            })
            .cloned()
            .collect();

        println!("ISA:");
        isa_instrs.iter().for_each(|(_, v)| {
            println!("{}", to_racket(v, (v.as_ref().len() - 1).into()).0.unwrap())
        });
    }

    #[test_log::test]
    fn explore_three_expressions() {
        let mut egraph: EGraph<Language, LanguageAnalysis> = EGraph::default();

        // https://github.com/mangpo/chlorophyll/tree/master/examples/bithack
        // Bithack 1.
        let _bithack1_id = egraph.add_expr(
            &RecExpr::from_str(
                "
(binop sub 8 (var x 8) (binop and 8 (var x 8) (var y 8)))
",
            )
            .unwrap(),
        );
        // Bithack 2.
        let _bithack2_id = egraph.add_expr(
            &RecExpr::from_str(
                "
(unop not 8 (binop sub 8 (var x 8) (var y 8)))
",
            )
            .unwrap(),
        );
        // Bithack 3.
        let _bithack3_id = egraph.add_expr(
            &RecExpr::from_str(
                "
(binop xor 8 (binop xor 8 (var x 8) (var y 8)) (binop and 8 (var x 8) (var y 8)))
",
            )
            .unwrap(),
        );

        let runner = Runner::default().with_egraph(egraph).run(&vec![
            introduce_hole_var(),
            fuse_op(),
            introduce_hole_op_both(),
            introduce_hole_op_left(),
            introduce_hole_op_right(),
            simplify_concat(),
            unary0(),
            unary1(),
            canonicalize(),
        ]);

        let isa_instrs: Vec<_> = find_isa_instructions(&runner.egraph)
            .par_iter()
            .filter(|(_, expr)| {
                if let (Some(racket_str), map) = to_racket(&expr, (expr.as_ref().len() - 1).into())
                {
                    println!("Attempting: {}", racket_str);
                    call_racket(racket_str, &map)
                } else {
                    false
                }
            })
            .cloned()
            .collect();

        println!("ISA:");
        isa_instrs.iter().for_each(|(instr_id, v)| {
            println!(
                "{} appears in:\nprogram {} {}\nprogram {} {}\nprogram {} {}",
                to_racket(v, (v.as_ref().len() - 1).into()).0.unwrap(),
                _bithack1_id,
                instr_appears_in_program(&runner.egraph, *instr_id, _bithack1_id),
                _bithack2_id,
                instr_appears_in_program(&runner.egraph, *instr_id, _bithack2_id),
                _bithack3_id,
                instr_appears_in_program(&runner.egraph, *instr_id, _bithack3_id),
            )
        });
    }

    #[test_log::test]
    fn test_canonicalize() {
        let mut egraph: EGraph<Language, LanguageAnalysis> = EGraph::default();
        let id = egraph.add_expr(&RecExpr::from_str("(canonicalize (list 1 3 2 3))").unwrap());

        let runner = Runner::default()
            .with_egraph(egraph)
            .run(&vec![canonicalize()]);

        "(canonical-args 0 1 2 1)"
            .parse::<Pattern<_>>()
            .unwrap()
            .search_eclass(&runner.egraph, id)
            .unwrap();
    }
}