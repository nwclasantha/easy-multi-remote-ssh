#!/usr/bin/perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec::Functions qw(catdir catfile);
use File::Basename qw(dirname basename);
use Getopt::Long;
use Pod::Usage;

use constant REAL_PROCESS_NAME => 'remote-ssh-access';

our $VERSION = '1.7';

my $procname = basename($0);
my $realname = REAL_PROCESS_NAME;

my ( $opt_help, $opt_silent, $opt_no_defkey, $opt_add );

GetOptions(
    's|silent'    => \$opt_silent,
    'h|help'      => \$opt_help,
    'N|no-defkey' => \$opt_no_defkey,
    'a|add'       => \$opt_add,
);

pod2usage(2) if $opt_help;

main(@ARGV);
exit(0);

sub main {
    my @args = @_;

    if ($opt_add) {
        add();
    } elsif ( $procname eq $realname ) {
        die sprintf( "This script (%s) should not be run directly, unless called with --add.\n", $realname );
    }

    my $settings = load_defaults();
    load_link_settings($settings);
    override_preferences($settings);
    run_ssh($settings, @args);
}

sub run_ssh {
    my ( $settings, @args ) = @_;
    my $cmd = build_ssh_cmd( $settings, @args );

    if ( !$opt_silent && !($settings->{cmd}) && !@args ) {
        $|++;
        printf( "%s%s\n", $settings->{override} ? '[*] ' : "", join( ' ', @$cmd ));
    }
    
    exec @$cmd;
}

sub build_ssh_cmd {
    my ( $settings, @args ) = @_;
    my $ssh_exec = path_of("ssh");
    my @cmd = ($ssh_exec);

    push @cmd, sprintf( '-%s', $settings->{version} ) if $settings->{version};
    push @cmd, ('-p', $settings->{port}) if $settings->{port};
    push @cmd, ('-i', $settings->{key}) if $settings->{key};
    push @cmd, ('-l', $settings->{user}) if $settings->{user};
    push @cmd, $settings->{host};
    push @cmd, @args ? @args : ($settings->{cmd}) if $settings->{cmd};

    return \@cmd;
}

sub path_of {
    my ($cmd) = @_;
    for my $dir (split /:/, $ENV{PATH}) {
        my $path = catfile($dir, $cmd);
        return $path if -x $path && -f _;
    }
    return;
}

sub load_link_settings {
    my ($settings) = @_;
    my $link = readlink($0) || $procname;
    $link =~ s|^[./]+||;

    my ($host, $user, $port, $key, $version, $cmd) = split(':', $link, 6);
    $settings->{host} = $host;
    $settings->{user} = $user if $user;
    $settings->{port} = getservbyname($port, 'tcp') || $port if $port && $port =~ /\D/;
    $settings->{key} = resolve_key($key) if $key;
    $settings->{version} = $version if $version && $version =~ /^\d$/;
    $settings->{cmd} = $cmd if $cmd;
}

sub override_preferences {
    my ($settings) = @_;
    my $pref_file = catfile(resolve_home(), ".remote-ssh-access");
    return unless -f $pref_file;

    open my $fh, '<', $pref_file or die "Cannot open preferences file: $!";
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
        chomp($line);

        my ($mhost, $muser, $mkey, $mver) = split(':', $line, 4);
        if ((lc($mhost) eq lc($settings->{host}) || $mhost eq '*') &&
            (lc($muser) eq lc($settings->{user}) || $muser eq '*')) {
            $settings->{key} = resolve_key($mkey) if $mkey;
            $settings->{version} = $mver if $mver =~ /^\d$/;
            $settings->{override} = 1;
        }
    }
    close $fh;
}

sub resolve_user {
    return (getpwuid($<))[0] || $ENV{USER} || getlogin() || die "Unable to determine username\n";
}

sub resolve_home {
    my $home_dir = (getpwuid($<))[7] || $ENV{HOME} || die "Unable to determine home directory\n";
    return $home_dir;
}

sub resolve_ssh_dir {
    return catdir(resolve_home(), '.ssh');
}

sub resolve_key {
    my ($key) = @_;
    $key =~ s/\.pub$//;
    my $key_file = catfile(resolve_ssh_dir(), $key);
    return -f $key_file ? $key_file : undef;
}

sub load_defaults {
    my $user = resolve_user();
    my $key_dir = resolve_ssh_dir();
    my $key_file = $opt_no_defkey ? undef : default_key($key_dir);

    return {
        user    => $user,
        key     => $key_file,
        port    => (getservbyname('ssh', 'tcp'))[2],
    };
}

sub default_key {
    my ($dir) = @_;
    my @keys = grep { -f } map { s/\.pub$//r } glob(catfile($dir, '*.pub'));
    return (sort { $a cmp $b } @keys)[0] // undef;
}

sub add {
    my @fields = (
        { prompt => "Hostname", required => 1, name => 'host' },
        { prompt => "Username", required => 0, name => 'user', blank => "All users", validate => \&validate_user },
        { prompt => "Port", required => 0, name => 'port', blank => (getservbyname('ssh', 'tcp'))[2], validate => qr/^\d+$/ },
        { prompt => "Public Key", required => 0, name => 'key', blank => "Default key", validate => \&resolve_key },
        { prompt => "Version", required => 0, name => 'version', validate => qr/^\d(?:\.\d+)?$/ },
        { prompt => "Command", required => 0, name => 'cmd', blank => "Login shell" },
        { prompt => "Shortcut", required => 1, name => 'short' },
    );

    my $dirpath = dirname(abs_path($0));
    die("Directory '$dirpath' isn't writable.") unless -w $dirpath;

    my $input = input_fields(\@fields);
    my $procfile = join(':', map { $_->{value} } @fields[0..5]);
    $procfile =~ s/:+$//;

    chdir($dirpath) or die "Can't change to $dirpath: $!";
    link abs_path($0), $procfile or die "Failed to create hard link: $!";
    symlink $procfile, $fields[-1]->{value} or die "Failed to create symlink: $!";
    print "Shortcut '$fields[-1]->{value}' has been created.\n";
}

sub input_fields {
    my ($fields) = @_;
    foreach my $field (@$fields) {
        my $prompt = sprintf("%s [%s] --> ", $field->{prompt}, $field->{blank} // '');
        my $value;
        while (1) {
            print $prompt;
            chomp($value = <STDIN>);
            $value ||= $field->{blank} if defined $field->{blank};
            last if !$field->{required} || ($field->{validate} ? $value =~ $field->{validate} : 1);
            print "Invalid input. Please try again.\n";
        }
        $field->{value} = $value;
    }
    return $fields;
}

sub validate_user {
    my ($user) = @_;
    return defined getpwnam($user);
}

__END__

=head1 NAME

remote-ssh-access - An application for creating handy SSH client shortcuts.

=head1 SYNOPSIS

    remote-ssh-access [-a|--add] [-h] [-s|--silent] [-N|--no-defkey] [cmds...]

=head1 DESCRIPTION

This script replaces the use of aliases or other small scripts for automating and managing SSH client commands.

=cut
