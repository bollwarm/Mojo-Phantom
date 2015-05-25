package Mojo::Phantom;

use Mojo::Base -base;

our $VERSION = '0.01';
$VERSION = eval $VERSION;

use File::Temp ();
use Mojo::Util;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON;
use Mojo::Template;
use Mojo::URL;
use JavaScript::Value::Escape;
use Scalar::Util;

use constant DEBUG => $ENV{MOJO_PHANTOM_DEBUG};

has base    => sub { Mojo::URL->new };
has bind    => sub { {} };
has cookies => sub { [] };
has package => 'main';
has 'setup';
has sep     => '--MOJO_PHANTOM_MSG--';

has template => <<'TEMPLATE';
  % my ($self, $url, $js) = @_;

  // Setup perl function
  function perl() {
    var system = require('system');
    var args = Array.prototype.slice.call(arguments);
    system.stdout.writeLine(JSON.stringify(args));
    system.stdout.writeLine('<%== $self->sep %>');
    system.stdout.flush();
  }

  // Setup error handling
  var onError = function(msg, trace) {
    var msgStack = ['PHANTOM ERROR: ' + msg];
    if (trace && trace.length) {
      msgStack.push('TRACE:');
      trace.forEach(function(t) {
        msgStack.push(' -> ' + (t.file || t.sourceURL) + ': ' + t.line + (t.function ? ' (in function ' + t.function +')' : ''));
      });
    }

    //phantom.exit isn't exitting immediately, so let Perl kill us
    perl('CORE::die', msgStack.join('\n'));
    //phantom.exit(1);
  };
  phantom.onError = onError;

  // Setup bound functions
  % my $bind = $self->bind || {};
  % foreach my $func (keys %$bind) {
    % my $target = $bind->{$func} || $func;
    perl.<%= $func %> = function() {
      perl.apply(this, ['<%== $target %>'].concat(Array.prototype.slice.call(arguments)));
    };
  % }

  // Setup Cookies
  % foreach my $cookie (@{ $self->cookies }) {
    % my $name = $cookie->name;
    phantom.addCookie({
      name: '<%== $name %>',
      value: '<%== $cookie->value %>',
      domain: '<%== $cookie->domain || $self->base->host %>',
    }) || perl.diag('Failed to import cookie <%== $name %>');
  % }

  // Requst page and inject user-provided javascript
  var page = require('webpage').create();
  page.onError = onError;

  // Additional setup
  <%= $self->setup || '' %>;

  page.open('<%== $url %>', function(status) {

    <%= $js %>;

    phantom.exit();
  });
TEMPLATE

sub execute_file {
  my ($self, $file, $cb) = @_;
  # note that $file might be an object that needs to have a strong reference

  my $pid = open my $pipe, '-|', 'phantomjs', "$file";
  die 'Could not spawn' unless defined $pid;
  my $stream = Mojo::IOLoop::Stream->new($pipe);
  my $id = Mojo::IOLoop->stream($stream);

  my $sep = $self->sep;
  my $package = $self->package;
  my $buffer = '';

  my $weak = $stream;
  my ($status, $error);
  Scalar::Util::weaken($weak);
  my $kill = sub {
    $error = shift if @_;
    return unless $pid;
    kill KILL => $pid;
    waitpid $pid, 0;
    $status = $?;
    $weak->close if $weak;
  };

  $stream->on(error => sub{ $kill->($_[1]) });

  $stream->on(read => sub {
    my ($stream, $bytes) = @_;
    warn "\nPerl <<<< Phantom: $bytes\n" if DEBUG;
    $buffer .= $bytes;
    while ($buffer =~ s/^(.*)\n$sep\n//) {
      my ($function, @args) = @{ Mojo::JSON::decode_json $1 };
      eval "package $package; no strict 'refs'; &{\$function}(\@args)";
      return $kill->($@) if $@;
    }
  });

  $stream->on(close => sub {
    warn "\nStream $pid closed\n" if DEBUG;
    undef $pid;
    undef $file;
    $status ||= $?;
    $self->$cb($error, $status);
  });

  return $kill;
}

sub execute_url {
  my ($self, $url, $js, $cb) = @_;

  $js = Mojo::Template
    ->new(escape => \&javascript_value_escape)
    ->render($self->template, $self, $url, $js);

  die $js if ref $js; # Mojo::Template returns Mojo::Exception objects on failure

  warn "\nPerl >>>> Phantom:\n$js\n" if DEBUG;
  my $tmp = File::Temp->new(SUFFIX => '.js');
  Mojo::Util::spurt($js => "$tmp");

  return $self->execute_file($tmp, $cb);
}

1;


=head1 NAME

Mojo::Phantom - Interact with your client side code via PhantomJS

=head1 SYNOPSIS

  use Mojolicious::Lite;

  use Test::More;
  use Test::Mojo::WithRoles qw/Phantom/;

  any '/' => 'index';

  my $t = Test::Mojo::WithRoles->new;
  $t->phantom_ok('/' => <<'JS');
    var text = page.evaluate(function(){
      return document.getElementById('name').innerHTML;
    });
    perl.is(text, 'Bender', 'name changed after loading');
  JS

  done_testing;

  __DATA__

  @@ index.html.ep

  <!DOCTYPE html>
  <html>
    <head></head>
    <body>
      <p id="name">Leela</p>
      <script>
        (function(){ document.getElementById('name').innerHTML = 'Bender' })();
      </script>
    </body>
  </html>

=head1 DESCRIPTION

Evaluate javascript tests using PhantomJS.

Javascript commands are executed and test data is extracted in a PhantomJS process.
The results are then shipped back to the Perl process and executed there.
Each invocation of the Javascript interpreter is presented to the test harness as a subtest.

This class is actually the transport mechanism of the system.
To learn more about using this for testing, see L<Test::Mojo::Role::Phantom/phantom_ok>.

=head1 ATTRIBUTES

L<Mojo::Phantom> inherits the attributes from L<Mojo::Base> and implements the following new ones.

=head2 base

An instance of L<Mojo::URL> used to make relative urls absolute.
This is used, for example, in setting cookies

=head2 bind

A hash reference used to bind JS methods and Perl functions.
Keys are methods to be created in the C<perl> object in javascript.
Values are functions for those methods to invoke when the message is received by the Perl process.
The functions may be relative to the L<package> or are absolute if they contain C<::>.
If the function is false, then the key is used as the function name.

=head2 cookies

An array reference containing L<Mojo::Cookie::Response> objects.

=head2 package

The package for binding relative function names.
Defaults to C<main>

=head2 setup

An additional string of javascript which is executed after the page object is created but before the url is opened.

=head2 sep

A string used to separate messages from the JS side.
Defaults to C<--MOJO_PHANTOM_MSG-->.

=head2 template

A string which is used to build a L<Mojo::Template> object.
It takes as its arguments the instance, a target url, and a string of javascript to be evaluated.

The default handles much of what this module does, you should be very sure of why you need to change this before doing so.

=head1 METHODS

L<Mojo::Phantom> inherits all methods from L<Mojo::Base> and implements the following new ones.

=head2 execute_file

A lower level function which handles the message passing etc.
You probably want L<execute_url>.
Takes a file path to start C<phantomjs> with and a callback.
Returns a function reference that can be invoked to kill the child process.

=head2 execute_url

Builds the template for PhantomJS to execute and starts it.
Takes a target url, a string of javascript to be executed in the context that the template provides and a callback.
By default this is the page context.
Returns a function reference that can be invoked to kill the child process.

=head1 SOURCE REPOSITORY

L<http://github.com/jberger/Test-Mojo-Phantom>

=head1 AUTHOR

Joel Berger, E<lt>joel.a.berger@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 by Joel Berger

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.