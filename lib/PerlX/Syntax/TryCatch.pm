package PerlX::Syntax::TryCatch;

# ABSTRACT Try::Tiny where 'return' works as it ought to.

use strict;
use warnings;
use Carp           qw/ carp croak cluck confess /;
use Try::Tiny      ();
use Devel::Declare ();

# TODO: see if 'parent' is already a dep of Devel::Declare
use base qw/ Devel::Declare::Context::Simple /;


use Data::Dumper;

# makes it easier to interpolate package names into generated code strings.
use vars qw/ $PST_PKG $EOB_PKG /;
BEGIN {
  $PST_PKG = __PACKAGE__;
  $EOB_PKG = "${PST_PKG}::EndOfBlockVal";
}

# declaring a namespace for the object that gets returned when the inner do-block
# ends because the end of the block was reached rather than being exited because
# of an explicit use of "return". I know it's not necessary, but it seems like
# The Right Thing To Do (tm)
BEGIN {
  eval "package $EOB_PKG";
}

# Also not necessary to declare these, but same rationale.
use vars qw/ @_RETVAL @_EOBVAL $_WANTARRAY /;

# report errors from these packages from the user's code
$Carp::Internal{ $_ } = 1 for qw/ Devel::Declare Devel::Declare::Context::Simple /;


### TODO: support "catch" and finally"

sub import {
  my $class  = shift;
  my $caller = caller;

  # install a 'try' sub into the caller's namespace
  {
    no strict 'refs';
    *{"${caller}::try"} = sub (&) {};

    # install TT's subs in this package with different names so they don't
    # confuse Devel::Decare (or perl's parser)
    *{"${PST_PKG}::tt_$_"} = \&{"Try::Tiny::$_"} for qw/ try catch finally /;
  }

  # then hook that sub with our transform sub
  Devel::Declare->setup_for(
      $caller,
      { try => { const => \&_transform_try } }
  );

}


# Given the value returned by "wantarray" (true, false, or undef), and a code
# ref, run the code ref with the context indicated by the wantarray value.
sub _run_with_context {
  my $wantarray = shift;
  my $code      = shift;

  die "$PST_PKG::_run_with_context *must* be run in list context"
    unless wantarray;

  if ( $wantarray ) {
    return $code->( @_ );
  }

  if ( defined $wantarray ) {
    return scalar $code->( @_ );
  }

  $code->( @_ ); # void context
  return;
}


# For better read/maintainability, I will format injected code nicely, but
# Devel::Declare needs it all in one line. Use this sub to "unformat" it.
sub _unformat_code {
  my ($code) = map {
    s/(?<!$)#[^\n]*//msg;  # remove comments (but avoid clobbering $#array)
    s/\n//msg;             # remove newlines
    s/\s+/ /msg;           # collapse whitespace
    $_;
  } join ' ', @_;
  return $code;
}



sub _code_before_try_block {
  return _unformat_code <<"END_CODE";
  ; # terminate the call to "try"
  # begin a bare block to constrain scope
  {

    # capture the current sub's return context
    local \$${PST_PKG}::_WANTARRAY = wantarray;

    # localise these to catch various values we will use later...
    local \@${PST_PKG}::_RETVAL;  # value returned by TT::try
    local \@${PST_PKG}::_EOBVAL;  # "End Of Block" value

    # call TT's try, saving the return value in _RETVAL. Note that
    # we're starting a new anonymous sub here, to pass to TT::try
    \@${PST_PKG}::_RETVAL =
      ${PST_PKG}::tt_try {

        # wrap the original try-block in a new anon sub to pass to
        # _run_with_context, which does what it says on the tin...
        return ${PST_PKG}::_run_with_context(
          \$${PST_PKG}::_WANTARRAY,
          sub  # the opening brace of the original try block will be right here.
END_CODE
}


sub _code_before_scope_injector {
  my ($ctx) = @_;

  # start a "do" block at the top of the try block (now a sub block). This do
  # block now "wraps" the original contents of the "try" block. If return is
  # not used within, the value of the last statement evaluated will be saved
  # in the localised _EOBVAL var.
  my $code_in_try_block_1 = "; \@${PST_PKG}::_EOBVAL = do {";
}


sub _code_after_try_block {
  return _unformat_code <<"END_CODE";
            # terminate the inner-most "do" block that will
            # wrap the original try block's code
            ;

            # if "return" was not used in the original code, we will end up
            # here. Turn _EOBVAL into an object to indicate what happened.
            \$${PST_PKG}::_EOBVAL[0] = bless [\@${PST_PKG}::_EOBVAL], "$EOB_PKG";

          }  # end of sub passed to _run_with_context
        );   # end of call to _run_with_context
      }      # end of sub passed to Try::Tiny::try
END_CODE
}


sub _code_after_all_blocks {
  return _unformat_code <<"END_CODE";
    # terminate the try-catch-finally construct (technically it's all just one
    # "statement" - all these blocks are just arguments to tt_try!)
    ;

    # we're back in the outer-most bare block, in the original sub. Look for
    # the sentinel object to determine if return was (not) used in any of the
    # try-catch blocks. If the sentinel is absent, use return now, with the
    # value we captured and the correct context.
    (\$${PST_PKG}::_WANTARRAY ? return \@${PST_PKG}::_RETVAL : return \$${PST_PKG}::_RETVAL[0])
      if ref(\$${PST_PKG}::_EOBVAL[0]) ne "$EOB_PKG";

  };  # terminate the final, outer-most block.
END_CODE
}


# this is the code the scope injector will be, um... injecting.
sub _code_in_scope_injector {
  my ($ctx) = @_;

  # TODO: rework this to support (optional) catch & finally blocks
  $ctx->_code_after_try_block . $ctx->_code_after_all_blocks
}

# generate code to inject the "after" code immediately after the closing
# brace of the inner "do" block is parsed:
sub _code_for_scope_injector {
  my ($ctx) = @_;

  return $ctx->scope_injector_call( $ctx->_code_in_scope_injector );
}

sub _code_in_try_block {
  my ($ctx) = @_;

  return _unformat_code(
    $ctx->_code_before_scope_injector,
    $ctx->_code_for_scope_injector,
  );
}



sub inject_code {
  my ($ctx, @lines) = @_;

  my $code = _unformat_code @lines;

  # retrieve the code that's been read, but not parsed so far (I think?)
  my $linestr = $ctx->get_linestr;

  return unless defined $linestr;  # Maybe this should be an error?

  # splice in the code at the current offset
  substr( $linestr, $ctx->offset, 0 ) = $code;

  # and update the line in the parser.
  $ctx->set_linestr( $linestr );

  # adjust the offset for the stuff we just spliced in
  $ctx->inc_offset( length $code );

  return 1;
}




# this is what gets called by Devel::Declare when the "try" sub is encountered
# in code using this module. It's where all the heavy lifting happens to
# transform the try-block into valid, working perl.
sub _transform_try {

  my $ctx = "$PST_PKG"->new->init( @_ );

  # our current position should be *just* before the "try" token.
  # move past it.
  $ctx->skip_declarator or croak "Could not parse try block";


  # turn the try sub we're transforming into a no-op with
  # no arguments, since that's how it will be used shortly...
  $ctx->shadow( sub () { } );


  # get the code to inject after the "try" and before the "{"
  my $code_before_try_block = $ctx->_code_before_try_block;

  #print "Injecting Before Try Block: [$code_before_try_block]\n";

  $ctx->inject_code( $code_before_try_block )
    or die "No code after try token";


  # get the code to inject *into* the original try block, right after the "{"
  # this code includes code that will inject more code at the end of the try
  # block using an end-of-scope hook into the parser.
  my $code_in_try_block = $ctx->_code_in_try_block;

  #print "Injecting Into Try Block: [$code_in_try_block]\n";

  # if the parser's current position isn't at the beginning of a block, its
  # not safe - the user probably has a bare "try" in their code?
  $ctx->inject_if_block( $code_in_try_block )
    or croak "Could not find a code block after try";

}




1 && q{ I'm a very, very bad man. }; # truth
__END__
