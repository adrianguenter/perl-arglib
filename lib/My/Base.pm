package My::Base;

use 5.018;
use utf8;
use warnings;

use Readonly;

use Sub::Exporter::Progressive -setup => {
  exports => [qw(__DIR__ sub_name $RE_HEX_BYTE $RE_HEX_2BYTES)],
  groups => {
    default => [qw(__DIR__ sub_name)],
    patterns => [qw($RE_HEX_BYTE $RE_HEX_2BYTES)],
  },
};

# BEGIN { $Exporter::Verbose=1 }

Readonly::Scalar our $RE_HEX_BYTE   => '[[:xdigit:]]{2}';
Readonly::Scalar our $RE_HEX_2BYTES => '[[:xdigit:]]{4}';

# Returns name of the calling subroutine (name of the subroutine sub_name is called from).
# The first argument increases position in call stack to support helper subs like FATAL.
sub sub_name { return ((caller(1+(@_ ? shift : 0)))[3]); }

sub __DIR__ { return dirname abs_path @{(caller)}[1]; }

1;
