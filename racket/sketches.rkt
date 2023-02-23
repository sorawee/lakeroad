;;; Lakeroad sketches.
;;;
;;; Lakeroad provides a number of synthesis sketches that should work across a wide range of
;;; platforms. Once a sketch is generated, it is architecture-dependent; to support users who would
;;; like to use new architectures with Lakeroad, we generate sketches using architecture-independent
;;; sketch generators. A sketch generator is a function which takes an architecture description, and
;;; uses that architecture description to generate an architecture-specific sketch. From the
;;; architecture description, the sketch generator is able to instantiate common interfaces like LUTs,
;;; MUXes, and DSPs, and the architecture description utilities (see architecture-description.rkt)
;;; will generate the architecture-specific instantiations of these interfaces.
;;;
;;; Sketch generators should return a list of two items:
;;; - The sketch, which is a Lakeroad expression with holes (i.e. symbolic Rosette values).
;;; - An opaque "internal data" object. This object is used to share symbolic state between
;;;   invocations of a sketch generator. If you would like to use a sketch generator multiple times to
;;;   generate a larger sketch, and you know that the symbolic state (e.g. the LUT memories) between
;;;   the two sketches should be the same (e.g. they're both performing addition), then you can pass
;;;   this internal data to the second invocation of the sketch generator.

#lang racket/base

(provide generate-sketch
         all-sketch-generators
         bitwise-sketch-generator
         bitwise-with-carry-sketch-generator
         carry-sketch-generator
         comparison-sketch-generator
         shallow-comparison-sketch-generator
         multiplication-sketch-generator
         shift-sketch-generator)

(require "architecture-description.rkt"
         "logical-to-physical.rkt"
         (prefix-in lr: "language.rkt")
         rosette
         rosette/lib/angelic
         rosette/lib/synthax
         racket/pretty
         "verilator.rkt"
         "utils.rkt")

;;; List of all sketch generators. Ordered roughly in terms of complexity/expected synthesis time.
(define (all-sketch-generators)
  (list bitwise-sketch-generator
        carry-sketch-generator
        bitwise-with-carry-sketch-generator
        comparison-sketch-generator
        multiplication-sketch-generator))

;;; Simple helper to generate an architecture-specific sketch for the given bitvector expression.
(define (generate-sketch sketch-generator architecture-description bv-expr)
  (first (sketch-generator architecture-description
                           (lr:list (map lr:bv (symbolics bv-expr)))
                           (length (symbolics bv-expr))
                           (apply max (bvlen bv-expr) (map bvlen (symbolics bv-expr))))))

;;; Generates a "bitwise" sketch, for operations like AND and OR.
;;;
;;; Bitwise operations are very simple: for n-bit inputs i0 and i1, bit 0 of i0 and bit 0 of i1 are
;;; paired together and put into a LUT, bit 1 of i0 and bit 1 of i1 are paired together and put into a
;;; LUT, and so on. This simple pattern is able to implement many useful operations.
;;;
;;; - logical-inputs: A Lakeroad list expression, representing a list of logical inputs. Each logical
;;;   input should have the same bitwidth.
;;; - num-logical-inputs: The number of logical inputs. This is used to determine the size of the LUTs
;;;   to be used.
;;; - bitwidth: The bitwidth of the inputs, which will also be the bitwidth of the output.
(define (bitwise-sketch-generator architecture-description
                                  logical-inputs
                                  num-logical-inputs
                                  bitwidth
                                  #:internal-data [internal-data #f])
  (match-let*
      ([_ 1] ;;; Dummy line to prevent formatter from messing up my comment structure.

       ;;; Unpack the internal data.
       [lut-internal-data (if internal-data (first internal-data) #f)]
       [logical-to-physical-chooser (if internal-data (second internal-data) (?? boolean?))]
       [physical-to-logical-chooser (if internal-data (third internal-data) (?? boolean?))]
       [logical-input-extension-choosers
        (if internal-data
            (fourth internal-data)
            (for/list ([i num-logical-inputs])
              (define-symbolic* logical-input-extension-chooser boolean?)
              logical-input-extension-chooser))]

       [logical-inputs
        (lr:list (for/list ([i num-logical-inputs] [chooser logical-input-extension-choosers])
                   (if chooser
                       (lr:zero-extend (lr:list-ref logical-inputs (lr:integer i))
                                       (lr:bitvector (bitvector bitwidth)))
                       (lr:dup-extend (lr:list-ref logical-inputs (lr:integer i))
                                      (lr:bitvector (bitvector bitwidth))))))]

       ;;; First, we construct a LUT just to get the `internal-data`. We will reuse this internal data
       ;;; to create more LUTs which use the same LUT memory. Note that if lut-internal-data is not #f
       ;;; above, then this function should simply pass it through and not change it, so it's
       ;;; effectively a no-op in the case where lut-internal-data isn't #f.
       [(list _ lut-internal-data)
        (construct-interface
         architecture-description
         (interface-identifier "LUT" (hash "num_inputs" num-logical-inputs))
         ;;; Note that we don't care what the inputs are hooked up to here, because we are
         ;;; just trying to get the internal data.
         (for/list ([i num-logical-inputs])
           (cons (format "I~a" i) (bv 0 1)))
         #:internal-data lut-internal-data)]

       ;;; Get physical inputs to luts by performing a logical-to-physical mapping.
       [physical-inputs (logical-to-physical-mapping
                         (if logical-to-physical-chooser (ltop-bitwise) (ltop-bitwise-reverse))
                         logical-inputs)]

       ;;; Construct the LUTs.
       [physical-outputs
        (lr:list
         (for/list ([i bitwidth])
           (let* ([physical-inputs-this-lut (lr:list-ref physical-inputs (lr:integer i))]
                  [port-map
                   (for/list ([i num-logical-inputs])
                     (cons (format "I~a" i)
                           (lr:extract (lr:integer i) (lr:integer i) physical-inputs-this-lut)))])
             (lr:hash-ref (first (construct-interface
                                  architecture-description
                                  (interface-identifier "LUT" (hash "num_inputs" num-logical-inputs))
                                  port-map
                                  #:internal-data lut-internal-data))
                          'O))))]

       ;;; Construct the output by mapping the physical outputs back to logical space and taking the
       ;;; first result.
       ;;;
       ;;; TODO(@gussmith23): Could support more results in the future.
       [logical-outputs (physical-to-logical-mapping
                         (if physical-to-logical-chooser (ptol-bitwise) (ptol-bitwise-reverse))
                         physical-outputs)]
       [out-expr (lr:list-ref logical-outputs (lr:integer 0))])

    (list out-expr
          (list lut-internal-data
                logical-to-physical-chooser
                physical-to-logical-chooser
                logical-input-extension-choosers))))

;;; Try using _only_ a carry chain! Pass the first logical input to DI
;;; and the second logical input to S.
(define (carry-sketch-generator architecture-description
                                logical-inputs
                                num-logical-inputs
                                bitwidth
                                #:internal-data [internal-data #f])
  (match-let* ([_ 1] ;;; Dummy line to prevent formatter from messing up comment structure
               [(list carry-expr internal-data)
                (construct-interface architecture-description
                                     (interface-identifier "carry" (hash "width" bitwidth))
                                     (list (cons "CI" (lr:bv (?? (bitvector 1))))
                                           (cons "DI" (lr:list-ref logical-inputs (lr:integer 0)))
                                           (cons "S" (lr:list-ref logical-inputs (lr:integer 1))))
                                     #:internal-data internal-data)]
               [out-expr (lr:hash-ref carry-expr 'O)])
    (list out-expr internal-data)))

;;; Bitwise with carry sketch generator.
;;;
;;; Suitable for arithmetic operations like addition and subtraction.
(define (bitwise-with-carry-sketch-generator architecture-description
                                             logical-inputs
                                             num-logical-inputs
                                             bitwidth
                                             #:internal-data [internal-data #f])
  (match-let*
      ([_ 1] ;;; Dummy line to prevent formatter from messing up my comment structure.

       ;;; Unpack the internal data.
       [bitwise-sketch-internal-data (if internal-data (first internal-data) #f)]
       [carry-internal-data (if internal-data (second internal-data) #f)]

       ;;; Generate a bitwise sketch over the inputs. We use this to generate the S signal.
       [(list bitwise-sketch bitwise-sketch-internal-data)
        (bitwise-sketch-generator architecture-description
                                  logical-inputs
                                  num-logical-inputs
                                  bitwidth
                                  #:internal-data bitwise-sketch-internal-data)]

       ;;; Pass the results into a carry. We populate the DI signal with one of the logical inputs.
       [(list carry-expr carry-internal-data)
        (construct-interface architecture-description
                             (interface-identifier "carry" (hash "width" bitwidth))
                             (list (cons "CI" (lr:bv (?? (bitvector 1))))
                                   (cons "DI" (lr:list-ref logical-inputs (lr:integer 0)))
                                   (cons "S" bitwise-sketch))
                             #:internal-data carry-internal-data)]

       ;;; Get the output from the carry.
       [out-expr (lr:hash-ref carry-expr 'O)])

    (list out-expr (list bitwise-sketch-internal-data carry-internal-data))))

;;; Comparison sketch generator.
;;;
;;; Very similar to bitwise with carry, but computes a function on *both* inputs to the carry. Returns
;;; a single bit. Given this name as it can be used to implement comparisions (especially because it
;;; just returns a single bit!)
;;;
;;; Note that we can adjust these sketches so that they return hashmaps, so both outputs are
;;; accessible.
(define (comparison-sketch-generator architecture-description
                                     logical-inputs
                                     num-logical-inputs
                                     bitwidth
                                     #:internal-data [internal-data #f])
  (match-let*
      ([_ 1] ;;; Dummy line to prevent formatter from messing up my comment structure.

       ;;; Unpack the internal data.
       [bitwise-sketch-0-internal-data (if internal-data (first internal-data) #f)]
       [bitwise-sketch-1-internal-data (if internal-data (second internal-data) #f)]
       [carry-internal-data (if internal-data (third internal-data) #f)]

       ;;; Generate a bitwise sketch over the inputs. We do this twice, one per carry input (DI and
       ;;; S). It may be the case that these can share internal data, but I'm not sure.
       [(list bitwise-sketch-0 bitwise-sketch-0-internal-data)
        (bitwise-sketch-generator architecture-description
                                  logical-inputs
                                  num-logical-inputs
                                  bitwidth
                                  #:internal-data bitwise-sketch-0-internal-data)]
       [(list bitwise-sketch-1 bitwise-sketch-1-internal-data)
        (bitwise-sketch-generator architecture-description
                                  logical-inputs
                                  num-logical-inputs
                                  bitwidth
                                  #:internal-data bitwise-sketch-1-internal-data)]

       ;;; Construct a carry, which will effectively do the reduction operation for the comparison.
       [(list carry-expr carry-internal-data)
        (construct-interface architecture-description
                             (interface-identifier "carry" (hash "width" bitwidth))
                             (list (cons "CI" (lr:bv (?? (bitvector 1))))
                                   (cons "DI" bitwise-sketch-0)
                                   (cons "S" bitwise-sketch-1))
                             #:internal-data carry-internal-data)]

       ;;; Return the carry out signal.
       [out-expr (lr:hash-ref carry-expr 'CO)])

    (list out-expr
          (list bitwise-sketch-0-internal-data bitwise-sketch-1-internal-data carry-internal-data))))

;;; A comparison sketch generator that makes efficient use of LUTs.
;;;
;;; This sketch generator starts by _densely packing_ all input signals into a
;;; row of LUTs: this means that multiple input bits are handled in a single LUT.
;;;
;;; This first row of LUTs then has its outputs densely packed into a second row
;;; of LUTs, which then is passed into a third row of LUTs etc, until only a
;;; single LUT remains. This has log depth in the size of the the input
(define (shallow-comparison-sketch-generator architecture-description
                                             logical-inputs
                                             num-logical-inputs
                                             bitwidth
                                             #:internal-data [internal-data #f])
  ;; Recursive helper function that builds the 'tree' portion of our circuit
  ;; (not including the top row)
  (define (helper inputs shared-internal-data)
    (cond
      [(= (length inputs) 0) (error "length of inputs should not be 0")]
      [(= (length inputs) 1) (list inputs shared-internal-data)]
      [else
       (match-let* ([(list outputs shared-internal-data)
                     (densely-pack-inputs-into-luts architecture-description
                                                    (list inputs)
                                                    #:internal-data shared-internal-data)])
         (helper outputs shared-internal-data))]))

  (match-let* ([_ 1] ;;; Dummy line to prevent formatter from messing up my comment structure.
               ;;; Unpack the internal data.
               [(list first-row-internal-data lut-tree-internal-data)
                (if internal-data internal-data (list #f #f))]

               ;;; Transform inputs into an explicit list of lists
               [inputs (for/list ([i num-logical-inputs])
                         (let ([input (lr:list-ref logical-inputs (lr:integer i))])
                           (for/list ([j bitwidth])
                             (lr:extract (lr:integer j) (lr:integer j) input))))]
               [(list first-row-outputs first-row-internal-data)
                (densely-pack-inputs-into-luts architecture-description
                                               inputs
                                               #:internal-data first-row-internal-data)]
               [(list lut-tree-expr-wrapped lut-tree-internal-data)
                (helper first-row-outputs lut-tree-internal-data)]
               ; We need to get the first item from helper's outputs, which is a
               ; list of hash-maps
               [lut-tree-expr (first lut-tree-expr-wrapped)]

               [out-expr lut-tree-expr])

    (list out-expr (list first-row-internal-data lut-tree-internal-data))))

;;; A comparison sketch generator that makes efficient use of LUTs that can
;;; handle bvult, etc.
;;;
;;; This sketch generator starts by _densely packing_ all input signals into a
;;; row of LUTs: this means that multiple input bits are handled in a single LUT.
;;;
;;; This first row of LUTs then has its outputs densely packed into a second row
;;; of LUTs, which then is passed into a third row of LUTs etc, until only a
;;; single LUT remains. This has log depth in the size of the the input
;;;
;;; NOTE: This is currently not functioning properly and is not exported
(define (double-shallow-comparison-sketch-generator architecture-description
                                                    logical-inputs
                                                    num-logical-inputs
                                                    bitwidth
                                                    #:internal-data [internal-data #f])
  ;; Recursive helper function that builds the 'tree' portion of our circuit
  ;; (not including the top row)
  (define (helper inputs shared-internal-data)
    (cond
      [(= (length inputs) 0) (error "length of inputs should not be 0")]
      [(= (length inputs) 1) (list inputs shared-internal-data)]
      [else
       (match-let* ([(list outputs shared-internal-data)
                     (densely-pack-inputs-into-luts architecture-description
                                                    (list inputs)
                                                    #:internal-data shared-internal-data)])
         (helper outputs shared-internal-data))]))

  (match-let* ([_ 1] ;;; Dummy line to prevent formatter from messing up my comment structure.
               ;;; Unpack the internal data.
               [(list first-row-a-internal-data first-row-b-internal-data lut-tree-internal-data)
                (if internal-data internal-data (list #f #f #f))]

               ;;; Transform inputs into an explicit list of lists
               [inputs (for/list ([i num-logical-inputs])
                         (let ([input (lr:list-ref logical-inputs (lr:integer i))])
                           (for/list ([j bitwidth])
                             (lr:extract (lr:integer j) (lr:integer j) input))))]
               ;;; Generate two rows: we need more than one bit of information
               ;;; output from each LUT: we need to know if a set of inputs is one of
               ;;; A_GT_B, A_EQ_B, or A_LT_B.
               [(list first-row-a-outputs first-row-a-internal-data)
                (densely-pack-inputs-into-luts architecture-description
                                               inputs
                                               #:internal-data first-row-a-internal-data)]
               [(list first-row-b-outputs first-row-b-internal-data)
                (densely-pack-inputs-into-luts architecture-description
                                               inputs
                                               #:internal-data first-row-b-internal-data)]
               ;;; We now want to interleave the outputs of rows a and b,
               ;;; transforming them from
               ;;;  (a0 a1 a2 a3) (b0 b1 b2 b3) to (a0 b0 a1 b1 a2 b2 a3 b3)
               ;;; NOTE: we need to ensure that ai and bi are always paired, and this is
               ;;; maintained by the `window-size` variable in
               ;;; `densely-pack-inputs-into-luts`: `window-size` is always even, and this means
               ;;; this means that even numbers of bits will always be packed together.
               [interleaved-outputs (interleave (list first-row-a-outputs first-row-b-outputs))]
               [(list lut-tree-expr-wrapped lut-tree-internal-data)
                (helper interleaved-outputs lut-tree-internal-data)]
               ; We need to get the first item from helper's outputs, which is a
               ; list of hash-maps
               [lut-tree-expr (first lut-tree-expr-wrapped)]

               [out-expr lut-tree-expr])

    (list out-expr
          (list first-row-a-internal-data first-row-b-internal-data lut-tree-internal-data))))
;;; Logical inputs should be a lr:list of length 2, where both bitvectors are the same length.
;;;
;;; We implement multiplication as (using four bits as an example):
;;;
;;;     a3   a2   a1   a0
;;; x   b3   b2   b1   b0
;;; ---------------------
;;;   a3b0 a2b0 a1b0 a0b0 (anbm represents an AND bm)
;;;   a2b1 a1b1 a0b1 1'b0
;;;   a1b2 a0b2 1'b0 1'b0
;;; + a0b3 1'b0 1'b0 1'b0
;;; ---------------------
;;;              <answer>
;;;
;;; Note that this works for signed, two's complement multiplication where the result is the same
;;; bitwidth as the inputs. I don't think this will work for "correct" multiplication, where the
;;; result is twice the bitwidth of the inputs.
(define (multiplication-sketch-generator architecture-description
                                         logical-inputs
                                         num-logical-inputs
                                         bitwidth
                                         #:internal-data [internal-data #f])
  (match-let*
      ([_ 0] ;;; Dummy line to prevent formatter from messing up my comments.

       ;;; Unpack the internal data.
       [and-lut-internal-data (if internal-data (first internal-data) #f)]
       [bitwise-with-carry-internal-data (if internal-data (second internal-data) #f)]

       [a-expr (lr:list-ref logical-inputs (lr:integer 0))]
       [b-expr (lr:list-ref logical-inputs (lr:integer 1))]

       ;;; Generate internal data to be shared across all AND luts.
       [(list _ and-lut-internal-data)
        (construct-interface architecture-description
                             (interface-identifier "LUT" (hash "num_inputs" 2))
                             (list (cons "I0" 'unused) (cons "I1" 'unused) (cons "I2" 'unused))
                             #:internal-data and-lut-internal-data)]

       ;;; List of ANDs.
       ;;;
       ;;; List of `bitwidth` expressions which have bitwidth `bitwidth`.
       [to-be-added-exprs
        (for/list ([row-i bitwidth])
          (lr:concat
           ;;; Note that we reverse the list; we produce ands in the order [a0b0, a1b0, a2b0, ...],
           ;;; which is LSB-first. So we reverse so that MSB is first when we concat. Note that it
           ;;; doesn't actually seem to matter---I suspect because bitwise-reverse can do the
           ;;; reversing during addition. But it's better to have it correct here.
           (lr:list
            (reverse
             (for/list ([col-i bitwidth])
               ;;; Only generate ANDs for the correct bits. Refer to our diagram above if you want to
               ;;; double check the condition on this if statement.
               (if (> row-i col-i)
                   (lr:bv (bv 0 1))
                   (lr:hash-ref
                    (first
                     (construct-interface
                      architecture-description
                      (interface-identifier "LUT" (hash "num_inputs" 2))
                      (list (cons "I0"
                                  (lr:extract (lr:integer (- col-i row-i))
                                              (lr:integer (- col-i row-i))
                                              a-expr))
                            (cons "I1" (lr:extract (lr:integer row-i) (lr:integer row-i) b-expr)))
                      #:internal-data and-lut-internal-data))
                    'O)))))))]

       ;;; Generate the internal data that will be shared across all of the sketches used to compute
       ;;; the additions.
       [(list _ bitwise-with-carry-internal-data)
        (bitwise-with-carry-sketch-generator architecture-description
                                             'unused
                                             2
                                             bitwidth
                                             #:internal-data bitwise-with-carry-internal-data)]

       ;;; TODO(@gussmith23): support more than 2 inputs on bitwise/bitwise-with-carry.
       [fold-fn (lambda (next-to-add-expr acc-expr)
                  (first (bitwise-with-carry-sketch-generator
                          architecture-description
                          (lr:list (list next-to-add-expr acc-expr))
                          2
                          bitwidth
                          #:internal-data bitwise-with-carry-internal-data)))]

       [out-expr (foldl fold-fn (lr:bv (bv 0 bitwidth)) to-be-added-exprs)])

    (list out-expr (list and-lut-internal-data bitwise-with-carry-internal-data))))

(define (shift-sketch-generator architecture-description
                                logical-inputs
                                num-logical-inputs
                                bitwidth
                                #:internal-data [internal-data #f])
  (when (not (equal? num-logical-inputs 2))
    (error "Shift sketch should take 2 inputs."))
  (match-let*
      ([_ 0] ;;; Dummy line to prevent formatter from messing up my comments.

       ;;; a is the value we're shifting, b is the value we're shifting it by.
       [a-expr (lr:list-ref logical-inputs (lr:integer 0))]
       [b-expr (lr:list-ref logical-inputs (lr:integer 1))]

       [logical-or-arithmetic-chooser (?? boolean?)]

       ;;; Generate the internal data for a mux2, so we can share it.
       [(list _ mux2-internal-data)
        (construct-interface architecture-description
                             (interface-identifier "MUX" (hash "num_inputs" 2))
                             (list (cons "I0" 'unused) (cons "I1" 'unused) (cons "S" 'unused))
                             #:internal-data #f)]

       [num-stages (exact-ceiling (log (add1 (add1 bitwidth)) 2))]
       ;;; I'm being lazy and throwing an extra stage in to fix bugs that were popping up. I don't
       ;;; think this extra stage is technically necessary, but it doesn't work without it.
       ;[num-stages (add1 num-stages)]
       ;;; Ok, now i'm just being extra lazy.
       ;;; TODO(@gussmith23): Make bitshifts actually efficient.
       [num-stages bitwidth]

       [(list _ or-internal-data)
        (construct-interface
         architecture-description
         (interface-identifier "LUT" (hash "num_inputs" (add1 (- bitwidth num-stages))))
         (for/list ([i (add1 (- bitwidth num-stages))])
           (cons (format "I~a" i) 'unused))
         #:internal-data #f)]

       [fold-fn
        (lambda (stage-i previous-stage-expr)
          (let* (;;; The selector bit for all the muxes in this row.
                 [s-expr (if (not (equal? stage-i (sub1 num-stages)))
                             (lr:extract (lr:integer stage-i) (lr:integer stage-i) b-expr)
                             ;;; for the last stage, the selector ORs all the remaining bits.
                             (lr:hash-ref (first (construct-interface
                                                  architecture-description
                                                  (interface-identifier
                                                   "LUT"
                                                   (hash "num_inputs" (add1 (- bitwidth num-stages))))
                                                  (for/list ([i (add1 (- bitwidth num-stages))])
                                                    (cons (format "I~a" i)
                                                          (lr:extract (lr:integer (+ stage-i i))
                                                                      (lr:integer (+ stage-i i))
                                                                      b-expr)))
                                                  #:internal-data or-internal-data))
                                          'O))]
                 [make-mux-fn
                  (lambda (bit-i)
                    (let* (;;; The bit to select for the i0 input of this mux.
                           [i0-bit bit-i]
                           [i0-expr
                            (lr:extract (lr:integer i0-bit) (lr:integer i0-bit) previous-stage-expr)]

                           ;;; The bit to select for the i1 input of this mux.
                           [i1-bit-right (+ bit-i (expt 2 stage-i))]
                           [i1-bit-left (- bit-i (expt 2 stage-i))]
                           [i1-value-right (if (>= i1-bit-right bitwidth)
                                               ;;; Either shift in 0s or the sign bit.
                                               (if logical-or-arithmetic-chooser
                                                   (lr:bv (bv 0 1))
                                                   (lr:extract (lr:integer (sub1 bitwidth))
                                                               (lr:integer (sub1 bitwidth))
                                                               a-expr))
                                               (lr:extract (lr:integer i1-bit-right)
                                                           (lr:integer i1-bit-right)
                                                           previous-stage-expr))]
                           [i1-value-left (if (< i1-bit-left 0)
                                              (lr:bv (bv 0 1))
                                              (lr:extract (lr:integer i1-bit-left)
                                                          (lr:integer i1-bit-left)
                                                          previous-stage-expr))]
                           [mux-expr-right
                            (first
                             (construct-interface
                              architecture-description
                              (interface-identifier "MUX" (hash "num_inputs" 2))
                              (list (cons "I0" i0-expr) (cons "I1" i1-value-right) (cons "S" s-expr))
                              #:internal-data mux2-internal-data))]
                           [mux-expr-left
                            (first
                             (construct-interface
                              architecture-description
                              (interface-identifier "MUX" (hash "num_inputs" 2))
                              (list (cons "I0" i0-expr) (cons "I1" i1-value-left) (cons "S" s-expr))
                              #:internal-data mux2-internal-data))]

                           [out-expr (lr:hash-ref (choose mux-expr-right mux-expr-left) 'O)])

                      out-expr))]

                 [out-expr (lr:concat (lr:list (reverse (for/list ([bit-i bitwidth])
                                                          (make-mux-fn bit-i)))))])
            out-expr))]

       [out-expr (foldl fold-fn a-expr (range num-stages))])
    (list out-expr (list))))

(module+ test
  (require rackunit
           "interpreter.rkt"
           "generated/lattice-ecp5-lut4.rkt"
           "generated/lattice-ecp5-ccu2c.rkt"
           "xilinx-ultrascale-plus-lut2.rkt"
           "generated/xilinx-ultrascale-plus-lut6.rkt"
           "generated/xilinx-ultrascale-plus-carry8.rkt"
           "generated/sofa-frac-lut4.rkt"
           rosette/solver/smt/boolector)

  (current-solver (boolector))

  (error-print-width 10000000000)
  (define-syntax-rule (sketch-test #:name name
                                   #:defines defines
                                   ...
                                   #:bv-expr bv-expr
                                   #:architecture-description architecture-description
                                   #:sketch-generator sketch-generator
                                   #:module-semantics module-semantics
                                   #:include-dirs include-dirs
                                   #:extra-verilator-args extra-verilator-args)
    (test-case
     name
     (with-terms
      (begin
        (displayln "--------------------------------------------------------------------------------")
        (displayln (format "running test ~a" name))
        defines ...

        (define start-sketch-gen-time (current-inexact-milliseconds))
        (define sketch (generate-sketch sketch-generator architecture-description bv-expr))
        ;;; (displayln sketch)

        (define end-sketch-gen-time (current-inexact-milliseconds))

        (displayln (format "number of symbolics in sketch: ~a" (length (symbolics sketch))))
        (displayln (format "sketch generation time: ~ams"
                           (- end-sketch-gen-time start-sketch-gen-time)))

        (define start-synthesis-time (current-inexact-milliseconds))

        (define result
          (with-vc (with-terms (synthesize #:forall (symbolics bv-expr)
                                           #:guarantee
                                           (assert (bveq bv-expr
                                                         (interpret sketch
                                                                    #:module-semantics
                                                                    module-semantics)))))))

        (define end-synthesis-time (current-inexact-milliseconds))
        (displayln (format "synthesis time: ~ams" (- end-synthesis-time start-synthesis-time)))

        (check-true (normal? result))
        (define soln (result-value result))
        (check-true (sat? soln))

        (define lr-expr
          (evaluate
           sketch
           ;;; Complete the solution: fill in any symbolic values that *aren't* the logical inputs.
           (complete-solution soln
                              (set->list (set-subtract (list->set (symbolics sketch))
                                                       (list->set (symbolics bv-expr)))))))

        (when (not (getenv "VERILATOR_INCLUDE_DIR"))
          (raise "VERILATOR_INCLUDE_DIR not set"))
        (check-true (simulate-with-verilator #:include-dirs include-dirs
                                             #:extra-verilator-args extra-verilator-args
                                             (list (to-simulate lr-expr bv-expr))
                                             (getenv "VERILATOR_INCLUDE_DIR")))))))

  (sketch-test
   #:name "left shift on SOFA"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bvshl a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  ;;; TODO(@gussmith23): Right shifts broken on SOFA
  ;; (sketch-test
  ;;  #:name "logical right shift on SOFA"
  ;;  #:defines (define-symbolic a b (bitvector 3))
  ;;  #:bv-expr (bvlshr a b)
  ;;  #:architecture-description (sofa-architecture-description)
  ;;  #:sketch-generator shift-sketch-generator
  ;;  #:module-semantics
  ;;  (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
  ;;  #:include-dirs
  ;;  (list
  ;;   (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
  ;;  #:extra-verilator-args
  ;;  "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")
  ;; (sketch-test
  ;;  #:name "arithmetic right shift on SOFA"
  ;;  #:defines (define-symbolic a b (bitvector 3))
  ;;  #:bv-expr (bvashr a b)
  ;;  #:architecture-description (sofa-architecture-description)
  ;;  #:sketch-generator shift-sketch-generator
  ;;  #:module-semantics
  ;;  (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
  ;;  #:include-dirs
  ;;  (list
  ;;   (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
  ;;   (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
  ;;  #:extra-verilator-args
  ;;  "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "logical right shift on lattice"
   #:defines (define-symbolic a b (bitvector 5))
   #:bv-expr (bvlshr a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "arithmetic right shift on lattice"
   #:defines (define-symbolic a b (bitvector 5))
   #:bv-expr (bvashr a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "left shift on lattice"
   #:defines (define-symbolic a b (bitvector 5))
   #:bv-expr (bvshl a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  ;;; TODO(@gussmith23): we have a bug in bvexpr->cexpr that's causing this to fail. (I think.)
  (sketch-test
   #:name "logical right shift on lattice"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bvlshr a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "arithmetic right shift on lattice"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bvashr a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "left shift on lattice"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bvshl a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shift-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "bitwise sketch generator on lattice"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bvand a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "bitwise sketch generator on lattice (2 bit mux)"
   #:defines (define-symbolic a b (bitvector 2))
   (define-symbolic sel (bitvector 1))
   #:bv-expr (if (not (bvzero? sel)) a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-sketch-generator
   #:module-semantics (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v")
                                  lattice-ecp5-lut4))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED")

  (sketch-test
   #:name "bitwise with carry sketch generator on ultrascale"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bvadd a b)
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator bitwise-with-carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;                             TEST COMPARISONS                             ;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  ;;; XILINX ULTRASCALE PLUS

  (sketch-test
   #:name "comparison sketch generator for bveq on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bveq on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvneq on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bvneq on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvneq on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bvneq on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvult on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (bvult a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvugt on ultrascale (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (bvugt a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  ; (sketch-test
  ;  #:name "shallow comparison sketch generator for bvugt on ultrascale (2 bit)"
  ;  #:defines (define-symbolic a b (bitvector 2))
  ;  #:bv-expr (bool->bitvector (bvugt a b))
  ;  #:architecture-description (xilinx-ultrascale-plus-architecture-description)
  ;  #:sketch-generator shallow-comparison-sketch-generator
  ;  #:module-semantics
  ;  (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
  ;        (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
  ;        (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
  ;  #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
  ;  #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bveq on ultrascale (4 bit)"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bveq on ultrascale (4 bit)"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvneq on ultrascale (4 bit)"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bvneq on ultrascale (4 bit)"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvult on ultrascale (4 bit)"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (bvult a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  ; (sketch-test
  ;  #:name "shallow comparison sketch generator for bvult on ultrascale (4 bit)"
  ;  #:defines (define-symbolic a b (bitvector 4))
  ;  #:bv-expr (bool->bitvector (bvult a b))
  ;  #:architecture-description (xilinx-ultrascale-plus-architecture-description)
  ;  #:sketch-generator shallow-comparison-sketch-generator
  ;  #:module-semantics
  ;  (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
  ;        (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
  ;        (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
  ;  #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
  ;  #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvugt on ultrascale (4 bit)"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (bvugt a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  ; (sketch-test
  ;  #:name "shallow comparison sketch generator for bvugt on ultrascale (4 bit)"
  ;  #:defines (define-symbolic a b (bitvector 4))
  ;  #:bv-expr (bool->bitvector (bvugt a b))
  ;  #:architecture-description (xilinx-ultrascale-plus-architecture-description)
  ;  #:sketch-generator shallow-comparison-sketch-generator
  ;  #:module-semantics
  ;  (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
  ;        (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
  ;        (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
  ;  #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
  ;  #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bveq on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bveq on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvneq on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bvneq on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvult on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (bvult a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  ; (sketch-test
  ;  #:name "shallow comparison sketch generator for bvult on ultrascale (8 bit)"
  ;  #:defines (define-symbolic a b (bitvector 8))
  ;  #:bv-expr (bool->bitvector (bvult a b))
  ;  #:architecture-description (xilinx-ultrascale-plus-architecture-description)
  ;  #:sketch-generator shallow-comparison-sketch-generator
  ;  #:module-semantics
  ;  (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
  ;        (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
  ;        (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
  ;  #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
  ;  #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvugt on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (bvugt a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  ; (sketch-test
  ;  #:name "shallow comparison sketch generator for bvugt on ultrascale (8 bit)"
  ;  #:defines (define-symbolic a b (bitvector 8))
  ;  #:bv-expr (bool->bitvector (bvugt a b))
  ;  #:architecture-description (xilinx-ultrascale-plus-architecture-description)
  ;  #:sketch-generator shallow-comparison-sketch-generator
  ;  #:module-semantics
  ;  (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
  ;        (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
  ;        (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
  ;  #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
  ;  #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bveq on ultrascale (16 bit)"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bveq on ultrascale (16 bit)"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvneq on ultrascale (16 bit)"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bvneq on ultrascale (16 bit)"
   #:defines (define-symbolic a b (bitvector 16))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bveq on ultrascale (32 bit)"
   #:defines (define-symbolic a b (bitvector 32))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bveq on ultrascale (32 bit)"
   #:defines (define-symbolic a b (bitvector 32))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "comparison sketch generator for bvneq on ultrascale (32 bit)"
   #:defines (define-symbolic a b (bitvector 32))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "shallow comparison sketch generator for bvneq on ultrascale (32 bit)"
   #:defines (define-symbolic a b (bitvector 32))
   #:bv-expr (bool->bitvector (not (bveq a b)))
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "multiplication sketch generator on ultrascale (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bvmul a b)
   #:architecture-description (xilinx-ultrascale-plus-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT2" "../verilator_xilinx/LUT2.v") xilinx-ultrascale-plus-lut2)
         (cons (cons "LUT6" "../verilator_xilinx/LUT6.v") xilinx-ultrascale-plus-lut6)
         (cons (cons "CARRY8" "../verilator_xilinx/CARRY8.v") xilinx-ultrascale-plus-carry8))
   #:include-dirs (list (build-path (get-lakeroad-directory) "verilator_xilinx"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING -Wno-WIDTH -Wno-TIMESCALEMOD")

  (sketch-test
   #:name "bitwise sketch generator on lattice"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bvand a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "bitwise with carry sketch generator on lattice"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-with-carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "bitwise with carry sketch generator on lattice (3 bit)"
   #:defines (define-symbolic a b (bitvector 3))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-with-carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "bitwise with carry sketch generator on lattice (1 bit)"
   #:defines (define-symbolic a b (bitvector 1))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-with-carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "bitwise with carry sketch generator on lattice (9 bit)"
   #:defines (define-symbolic a b (bitvector 9))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator bitwise-with-carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "carry sketch generator on lattice"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "carry sketch generator on lattice (3 bit)"
   #:defines (define-symbolic a b (bitvector 3))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "carry sketch generator on lattice (1 bit)"
   #:defines (define-symbolic a b (bitvector 1))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "carry sketch generator on lattice (9 bit)"
   #:defines (define-symbolic a b (bitvector 9))
   #:bv-expr (bvadd a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator carry-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "comparison sketch generator on lattice"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "shallow comparison sketch generator on lattice"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "multiplication sketch generator on lattice (1 bit)"
   #:defines (define-symbolic a b (bitvector 1))
   #:bv-expr (bvmul (zero-extend a (bitvector 1)) (zero-extend b (bitvector 1)))
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "multiplication sketch generator on lattice (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bvmul a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "multiplication sketch generator on lattice (3 bit)"
   #:defines (define-symbolic a b (bitvector 3))
   #:bv-expr (bvmul a b)
   #:architecture-description (lattice-ecp5-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "LUT4" "../f4pga-arch-defs/ecp5/primitives/slice/LUT4.v") lattice-ecp5-lut4)
         (cons (cons "CCU2C" "../f4pga-arch-defs/ecp5/primitives/slice/CCU2C.v") lattice-ecp5-ccu2c))
   #:include-dirs (list (build-path (get-lakeroad-directory) "f4pga-arch-defs/ecp5/primitives/slice"))
   #:extra-verilator-args "-Wno-UNUSED -Wno-PINMISSING")

  (sketch-test
   #:name "bitwise on SOFA"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bvand a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator bitwise-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "bitwise with carry on SOFA"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bvadd a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator bitwise-with-carry-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "comparison sketch on SOFA"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  ;;; TODO(acheung8): This one's the long one.
  ;;; interestingly, bveq with two bvs w/ width 4 is fast. this requires a LUT 8?
  ;;; todo: explore if bwidth of 5 seems to exponentially explode # of symbolics
  (sketch-test
   #:name "shallow comparison sketch on SOFA"
   #:defines (define-symbolic a b (bitvector 4))
   #:bv-expr (bool->bitvector (bveq a b))
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator shallow-comparison-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "multiplication sketch on SOFA (1bit)"
   #:defines (define-symbolic a b (bitvector 1))
   #:bv-expr (bvmul a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "multiplication sketch on SOFA (2 bit)"
   #:defines (define-symbolic a b (bitvector 2))
   #:bv-expr (bvmul a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "multiplication sketch on SOFA (3 bits)"
   #:defines (define-symbolic a b (bitvector 3))
   #:bv-expr (bvmul a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES")

  (sketch-test
   #:name "multiplication sketch on SOFA (8 bit)"
   #:defines (define-symbolic a b (bitvector 8))
   #:bv-expr (bvmul a b)
   #:architecture-description (sofa-architecture-description)
   #:sketch-generator multiplication-sketch-generator
   #:module-semantics
   (list (cons (cons "frac_lut4" "../modules_for_importing/SOFA/frac_lut4.v") sofa-frac-lut4))
   #:include-dirs
   (list
    (build-path (get-lakeroad-directory) "modules_for_importing" "SOFA")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/or2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/inv/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/buf/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd/cells/mux2/")
    (build-path (get-lakeroad-directory) "skywater-pdk-libs-sky130_fd_sc_hd" "models" "udp_mux_2to1"))
   #:extra-verilator-args
   "-Wno-LITENDIAN -Wno-EOFNEWLINE -Wno-UNUSED -Wno-PINMISSING -Wno-TIMESCALEMOD -DSKY130_FD_SC_HD__UDP_MUX_2TO1_LAKEROAD_HACK -DNO_PRIMITIVES"))