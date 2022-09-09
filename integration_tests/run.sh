set -e
set -u

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

lit -v $SCRIPT_DIR/convert-module-to-btor/
lit -v $SCRIPT_DIR/verilog_to_racket/