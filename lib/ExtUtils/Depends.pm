#
# $Header: /cvsroot/gtk2-perl/gtk2-perl-xs/ExtUtils-Depends/lib/ExtUtils/Depends.pm,v 1.14 2005/01/23 18:49:49 muppetman Exp $
#

package ExtUtils::Depends;

use strict;
use warnings;
use Carp;
use File::Spec;
use Data::Dumper;

our $VERSION = '0.205';

sub import {
	my $class = shift;
	return unless @_;
        die "$class version $_[0] is required--this is only version $VERSION"
		if $VERSION < $_[0];
}

sub new {
	my ($class, $name, @deps) = @_;
	my $self = bless {
		name => $name,
		deps => {},
		inc => [],
		libs => '',

		pm => {},
		typemaps => [],
		xs => [],
		c => [],
	}, $class;

	$self->add_deps (@deps);

	# attempt to load these now, so we'll find out as soon as possible
	# whether the dependencies are valid.  we'll load them again in
	# get_makefile_vars to catch any added between now and then.
	$self->load_deps;

	return $self;
}

sub add_deps {
	my $self = shift;
	foreach my $d (@_) {
		$self->{deps}{$d} = undef
			unless $self->{deps}{$d};
	}
}

sub get_deps {
	my $self = shift;
	$self->load_deps; # just in case

	return %{$self->{deps}};
}

sub set_inc {
	my $self = shift;
	push @{ $self->{inc} }, @_;
}

sub set_libs {
	my ($self, $newlibs) = @_;
	$self->{libs} = $newlibs;
}

sub add_pm {
	my ($self, %pm) = @_;
	while (my ($key, $value) = each %pm) {
		$self->{pm}{$key} = $value;
	}
}

sub _listkey_add_list {
	my ($self, $key, @list) = @_;
	$self->{$key} = [] unless $self->{$key};
	push @{ $self->{$key} }, @list;
}

sub add_xs       { shift->_listkey_add_list ('xs',       @_) }
sub add_c        { shift->_listkey_add_list ('c',        @_) }
sub add_typemaps {
	my $self = shift;
	$self->_listkey_add_list ('typemaps', @_);
	$self->install (@_);
}

# no-op, only used for source back-compat
sub add_headers { carp "add_headers() is a no-op" }

####### PRIVATE
sub basename { (File::Spec->splitdir ($_[0]))[-1] }
# get the name in Makefile syntax.
sub installed_filename {
	my $self = shift;
	return '$(INST_ARCHLIB)/$(FULLEXT)/Install/'.basename ($_[0]);
}

sub install {
	# install things by adding them to the hash of pm files that gets
	# passed through WriteMakefile's PM key.
	my $self = shift;
	foreach my $f (@_) {
		$self->add_pm ($f, $self->installed_filename ($f));
	}
}

sub save_config {
	use Data::Dumper;
	use IO::File;

	my ($self, $filename) = @_;
	warn "Writing $filename\n";

	my $file = IO::File->new (">".$filename)
		or croak "can't open '$filename' for writing: $!\n";

	print $file "package $self->{name}\::Install::Files;\n\n";
	# for modern stuff
	print $file "".Data::Dumper->Dump([{
		inc => join (" ", @{ $self->{inc} }),
		libs => $self->{libs},
		typemaps => [ map { basename $_ } @{ $self->{typemaps} } ],
		deps => [keys %{ $self->{deps} }],
	}], ['self']);
	# for ancient stuff
	print $file "\n\n# this is for backwards compatiblity\n";
	print $file "\@deps = \@{ \$self->{deps} };\n";
	print $file "\@typemaps = \@{ \$self->{typemaps} };\n";
	print $file "\$libs = \$self->{libs};\n";
	print $file "\$inc = \$self->{inc};\n";
	# this is riduculous, but old versions of ExtUtils::Depends take
	# first $loadedmodule::CORE and then $INC{$file} --- the fallback
	# includes the Filename.pm, which is not useful.  so we must add
	# this crappy code.  we don't worry about portable pathnames,
	# as the old code didn't either.
	(my $mdir = $self->{name}) =~ s{::}{/}g;
	print $file <<"EOT";

	\$CORE = undef;
	foreach (\@INC) {
		if ( -f \$_ . "/$mdir/Install/Files.pm") {
			\$CORE = \$_ . "/$mdir/Install/";
			last;
		}
	}
EOT

	print $file "\n1;\n";

	close $file;

	# we need to ensure that the file we just created gets put into
	# the install dir with everything else.
	#$self->install ($filename);
	$self->add_pm ($filename, $self->installed_filename ('Files.pm'));
}

sub load {
	my $dep = shift;
	my @pieces = split /::/, $dep;
	my @suffix = qw/ Install Files /;
	my $relpath = File::Spec->catfile (@pieces, @suffix) . '.pm';
	my $depinstallfiles = join "::", @pieces, @suffix;
	eval {
		require $relpath 
	} or die " *** Can't load dependency information for $dep:\n   $@\n";
	#
	#print Dumper(\%INC);

	# effectively $instpath = dirname($INC{$relpath})
	@pieces = File::Spec->splitdir ($INC{$relpath});
	pop @pieces;
	my $instpath = File::Spec->catdir (@pieces);
	
	no strict;

	croak "No dependency information found for $dep"
		unless $instpath;

	warn "Found $dep in $instpath\n";

	if (not File::Spec->file_name_is_absolute ($instpath)) {
		warn "instpath is not absolute; using cwd...\n";
		$instpath = File::Spec->rel2abs ($instpath);
	}

	my @typemaps = map {
		File::Spec->rel2abs ($_, $instpath)
	} @{"$depinstallfiles\::typemaps"};

	{
		instpath => $instpath,
		typemaps => \@typemaps,
		inc      => "-I$instpath ".${"$depinstallfiles\::inc"},
		libs     => ${"$depinstallfiles\::libs"},
		# this will not exist when loading files from old versions
		# of ExtUtils::Depends.
		(exists ${"$depinstallfiles\::"}{deps}
		  ? (deps => \@{"$depinstallfiles\::deps"})
		  : ()), 
	}
}

sub load_deps {
	my $self = shift;
	my @load = grep { not $self->{deps}{$_} } keys %{ $self->{deps} };
	foreach my $d (@load) {
		my $dep = load ($d);
		$self->{deps}{$d} = $dep;
		if ($dep->{deps}) {
			foreach my $childdep (@{ $dep->{deps} }) {
				push @load, $childdep
					unless
						$self->{deps}{$childdep}
					or
						grep {$_ eq $childdep} @load;
			}
		}
	}
}

sub uniquify {
	my %seen;
	# we use a seen hash, but also keep indices to preserve
	# first-seen order.
	my $i = 0;
	foreach (@_) {
		$seen{$_} = ++$i
			unless exists $seen{$_};
	}
	#warn "stripped ".(@_ - (keys %seen))." redundant elements\n";
	sort { $seen{$a} <=> $seen{$b} } keys %seen;
}


sub get_makefile_vars {
	my $self = shift;

	# collect and uniquify things from the dependencies.
	# first, ensure they are completely loaded.
	$self->load_deps;
	
	##my @defbits = map { split } @{ $self->{defines} };
	my @incbits = map { split } @{ $self->{inc} };
	my @libsbits = split /\s+/, $self->{libs};
	my @typemaps = @{ $self->{typemaps} };
	foreach my $d (keys %{ $self->{deps} }) {
		my $dep = $self->{deps}{$d};
		#push @defbits, @{ $dep->{defines} };
		push @incbits, @{ $dep->{defines} } if $dep->{defines};
		push @incbits, split /\s+/, $dep->{inc} if $dep->{inc};
		push @libsbits, split /\s+/, $dep->{libs} if $dep->{libs};
		push @typemaps, @{ $dep->{typemaps} } if $dep->{typemaps};
	}

	# we have a fair bit of work to do for the xs files...
	my @clean = ();
	my @OBJECT = ();
	my %XS = ();
	foreach my $xs (@{ $self->{xs} }) {
		(my $c = $xs) =~ s/\.xs$/\.c/i;
		(my $o = $xs) =~ s/\.xs$/\$(OBJ_EXT)/i;
		$XS{$xs} = $c;
		push @OBJECT, $o;
		# according to the MakeMaker manpage, the C files listed in
		# XS will be added automatically to the list of cleanfiles.
		push @clean, $o;
	}

	# we may have C files, as well:
	foreach my $c (@{ $self->{c} }) {
		(my $o = $c) =~ s/\.c$/\$(OBJ_EXT)/i;
		push @OBJECT, $o;
		push @clean, $o;
	}

	my %vars = (
		INC => join (' ', uniquify @incbits),
		LIBS => join (' ', uniquify @libsbits),
		TYPEMAPS => [@typemaps],
	);
	# we don't want to provide these if there is no data in them;
	# that way, the caller can still get default behavior out of
	# MakeMaker when INC, LIBS and TYPEMAPS are all that are required.
	$vars{PM} = $self->{pm}
		if %{ $self->{pm} };
	$vars{clean} = { FILES => join (" ", @clean), }
		if @clean;
	$vars{OBJECT} = join (" ", @OBJECT)
		if @OBJECT;
	$vars{XS} = \%XS
		if %XS;

	%vars;
}

1;

__END__

=head1 NAME

ExtUtils::Depends - Easily build XS extensions that depend on XS extensions

=head1 SYNOPSIS

	use ExtUtils::Depends;
	$package = new ExtUtils::Depends ('pkg::name', 'base::package')
	# set the flags and libraries to compile and link the module
	$package->set_inc("-I/opt/blahblah");
	$package->set_lib("-lmylib");
	# add a .c and an .xs file to compile
	$package->add_c('code.c');
	$package->add_xs('module-code.xs');
	# add the typemaps to use
	$package->add_typemaps("typemap");
	# install some extra data files and headers
	$package->install (qw/foo.h data.txt/);
	# save the info
	$package->save_config('Files.pm');

	WriteMakefile(
		'NAME' => 'Mymodule',
		$package->get_makefile_vars()
	);

=head1 DESCRIPTION

This module tries to make it easy to build Perl extensions that use
functions and typemaps provided by other perl extensions. This means
that a perl extension is treated like a shared library that provides
also a C and an XS interface besides the perl one.

This works as long as the base extension is loaded with the RTLD_GLOBAL
flag (usually done with a 

	sub dl_load_flags {0x01}

in the main .pm file) if you need to use functions defined in the module.

The basic scheme of operation is to collect information about a module
in the instance, and then store that data in the Perl library where it
may be retrieved later.  The object can also reformat this information
into the data structures required by ExtUtils::MakeMaker's WriteMakefile
function.

When creating a new Depends object, you give it a name, which is the name
of the module you are building.   You can also specify the names of modules
on which this module depends.  These dependencies will be loaded
automatically, and their typemaps, header files, etc merged with your new
object's stuff.  When you store the data for your object, the list of
dependencies are stored with it, so that another module depending on your
needn't know on exactly which modules yours depends.

For example:

  Gtk2 depends on Glib

  Gnome2::Canvas depends on Gtk2

  ExtUtils::Depends->new ('Gnome2::Canvas', 'Gtk2');
     this command automatically brings in all the stuff needed
     for Glib, since Gtk2 depends on it.


=head1 METHODS

=over

=item $object = ExtUtils::Depends->new($name, @deps)

Create a new depends object named I<$name>.  Any modules listed in I<@deps>
(which may be empty) are added as dependencies and their dependency
information is loaded.  An exception is raised if any dependency information
cannot be loaded.

=item $depends->add_deps (@deps)

Add modules listed in I<@deps> as dependencies.

=item (hashes) = $depends->get_deps

Fetch information on the dependencies of I<$depends> as a hash of hashes,
which are dependency information indexed by module name.  See C<load>.

=item $depends->set_inc (@newinc)

Add strings to the includes or cflags variables.

=item $depends->set_libs (@newlibs)

Add strings to the libs (linker flags) variable.

=item $depends->add_pm (%pm_files)

Add files to the hash to be passed through ExtUtils::WriteMakefile's
PM key.

=item $depends->add_xs (@xs_files)

Add xs files to be compiled.

=item $depends->add_c (@c_files)

Add C files to be compiled.

=item $depends->typemaps (@typemaps)

Add typemap files to be used and installed.

=item $depends->add_headers (list)

No-op, for backward compatibility.

=item $depends->install (@files)

Install I<@files> to the data directory for I<$depends>.

This actually works by adding them to the hash of pm files that gets
passed through WriteMakefile's PM key.

=item $depends->save_config ($filename)

Save the important information from I<$depends> to I<$filename>, and
set it up to be installed as I<name>::Install::Files.

Note: the actual value of I<$filename> seems to be irrelevant, but its
usage is kept for backward compatibility.

=item hash = $depends->get_makefile_vars

Return the information in I<$depends> in a format digestible by
WriteMakefile.

This sets at least the following keys:

	INC
	LIBS
	TYPEMAPS
	PM

And these if there is data to fill them:

	clean
	OBJECT
	XS

=item hashref = ExtUtils::Depends::load (name)

Load and return dependency information for I<name>.  Croaks if no such
information can be found.  The information is returned as an anonymous
hash containing these keys:

=over

=item instpath

The absolute path to the data install directory for this module.

=item typemaps

List of absolute pathnames for this module's typemap files.

=item inc

CFLAGS string for this module.

=item libs

LIBS string for this module.

=item deps

List of modules on which this one depends.  This key will not exist when
loading files created by old versions of ExtUtils::Depends.

=back

=item $depends->load_deps

Load I<$depends> dependencies, by calling C<load> on each dependency module.
This is usually done for you, and should only be needed if you want to call
C<get_deps> after calling C<add_deps> manually.

=back


=head1 BUGS

As written, this module expects that RTLD_GLOBAL works on your platform,
which is not always true, most notably, on win32.  We need to include a
way to find the actual shared libraries created for extension modules
so new extensions may be linked explicitly with them.

Version 0.2 discards some of the more esoteric features provided by the
older versions.  As they were completely undocumented, and this module
has yet to reach 1.0, this may not exactly be a bug.

This module is tightly coupled to the ExtUtils::MakeMaker architecture.

=head1 SEE ALSO

ExtUtils::MakeMaker.

=head1 AUTHOR

Paolo Molaro <lupus at debian dot org> wrote the original version for
Gtk-Perl.  muppet <scott at asofyet dot org> rewrote the innards for
version 0.2, borrowing liberally from Paolo's code.

=head1 MAINTAINER

The Gtk2 project, http://gtk2-perl.sf.net/

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut

