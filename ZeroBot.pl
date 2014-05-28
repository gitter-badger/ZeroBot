#!/usr/bin/env perl

use v5.14;
use strict;
use warnings;

use POE qw(Component::IRC::State);

use DBI;
use Digest::MD5 qw(md5_hex);
use Digest::SHA qw(sha256_hex sha512_hex);
use Digest::CRC qw(crc32_hex);
use MIME::Base64;

use ZeroBot::module::test;

# TODO: make randomization a bit better and remember last used phrase for all
# tables, then skip it if it comes up again back-to-back

# TODO: move this somewhere that makes sense
srand(time);

my $botversion = '0.1a';
my $cmdprefix = '!';
my $should_respawn = 0;

# TODO: move this to config-related shit
my %networks = (
    wazuhome => {
        servers => ['wazu.info.tm'],
        channels => ['#zerobot'],
        nickname => 'ZeroBot',
        username => 'ZeroBot',
        realname => "ZeroBot v$botversion",
    },
);
# XXX: temporary
$networks{wazuhome}{channels} = ["$ARGV[0]"] if $ARGV[0];

# TODO: move this to database-related shit
my $dbfile = 'zerobot.db';
my $dsn = "dbi:SQLite:dbname=$dbfile";
my $dbh = DBI->connect($dsn, '', '', {
    PrintError       => 1,
    RaiseError       => 0,
    AutoCommit       => 0,
    FetchHashKeyName => 'NAME_lc',
});

# create a new poco-irc object
our $poco_irc = POE::Component::IRC::State->spawn(
    nick => $networks{wazuhome}{nickname},
    username => $networks{wazuhome}{username},
    ircname => $networks{wazuhome}{realname},
    server => $networks{wazuhome}{servers}[0],
    flood => 1,
) or die "spawn: failed to create IRC object; $!";

POE::Session->create(
    package_states => [
        main => [ qw(
            _default
            _start
            _stop
            irc_001
            irc_433
            irc_public
            irc_ctcp_action
            irc_msg
            irc_join
        ) ],
    ],
    heap => {
        poco_irc => $poco_irc,
        game => {
            roulette => {
                bullet => int(rand(6)),
                shot => 0,
            },
            nguess => {
                magicnum => int(rand(100)) + 1,
                guessnum => 0,
            }
        },
    },
);

$poe_kernel->run();

sub _start {
    my $heap = $_[HEAP];

    # Get the session ID of the irc component from the object created by
    # POE::Session->create()
    my $irc_session = $heap->{poco_irc}->session_id();

    # Register for all irc events. Non-explicitly handled events will fall back
    # to _default()
    $poco_irc->yield(register => 'all');

    # Connect to the server
    $poco_irc->yield(connect => { });
    return;
}

sub irc_001 {
    # RPL_WELCOME
    my $sender = $_[SENDER];

    # Get the component's object by accessing the SENDER's heap
    # In any irc_* events, SENDER will be the PoCo-IRC session.
    my $poco_irc = $sender->get_heap();
    say "Connected to ", $poco_irc->server_name();

    # Join our channels now that we're connected
    $poco_irc->yield(join => $_) for @{$networks{wazuhome}{channels}};
    return;
}

sub irc_433 {
    # ERR_NICKNAMEINUSE
    my $nick = $poco_irc->nick_name;

    say "Nick: '$nick' already in use.";
    $poco_irc->yield(nick => $nick . '_');
}

sub irc_public {
    my ($sender, $heap, $who, $where, $what) = @_[SENDER, HEAP, ARG0 .. ARG2];
    my $poco_irc = $sender->get_heap();
    my $me = $poco_irc->nick_name;
    my $nick = (split /!/, $who)[0];
    my $channel = $where->[0];
    my $is_chanop = $poco_irc->is_channel_operator($channel, $me);

    given ($what) {
        when ($nick eq 'xxen0nxx') {
            chat_trollxeno($channel) if module_enabled('chat_trollxeno');
        } when (/^$cmdprefix/) {
            my @cmd = parse_command($what);
            given ($cmd[0]) {
                when ('encode') { # TODO: add more encodings
                    if (my $output = cmd_encode($cmd[1], "@cmd[2..$#cmd]", $channel)) {
                        $poco_irc->yield(privmsg => $channel => "$nick: @cmd[2..$#cmd] = $output");
                    } else {
                        return;
                    }
                } when ('roulette') {
                    cmd_roulette($heap, $channel, $nick);
                } when ('guess') {
                    cmd_nguess($heap, $channel, $nick, $cmd[1]);
                } when ('8ball') {
                    if ($what =~ /.+\?$/) {
                        cmd_8ball($channel, $nick);
                    } else {
                        cmd_8ball_not_question($channel, $nick);
                    }
                } when ('restart') {
                    if ($nick eq 'ZeroKnight') {
                        $should_respawn = 1;
                        $poco_irc->call(privmsg => $channel => "Okay, brb!"); # FIXME
                        $poco_irc->yield(shutdown => "Restarted by $nick");
                    }
                } when ('die') {
                    if ($nick eq 'ZeroKnight') {
                        $poco_irc->call(privmsg => $channel => "Okay :("); # FIXME
                        $poco_irc->yield(shutdown => "Killed by $nick");
                    }
                } when ('say') {
                    if ($cmd[1] !~ /roulette/) {
                        # Normal puppetting
                        $poco_irc->yield(privmsg => $channel => "@cmd[1..$#cmd]");
                    } else {
                        # Nice try, wise guy
                        $poco_irc->call(ctcp => $channel =>
                            "ACTION laughs and rotates the chamber, pointing the gun at $nick"
                        );
                        if ($is_chanop) {
                            $poco_irc->yield(kick => $channel => $nick =>
                                "BANG! You aren't as clever as you think."
                            );
                        } else {
                            $poco_irc->yield(privmsg => $channel =>
                                "BANG! You aren't as clever as you think."
                            );
                        }
                        cmd_roulette_reload($heap, $channel);
                    }
                } when ('test') {
                    test($channel);
                } default {
                    chat_badcmd($channel) if module_enabled('chat_badcmd');
                }
            }
        } when ( # TODO: add variety/variances
            /right,? $me\s?\??/i or
            /$me,? .*(right)?\?/ or
            /,? $me\?/ or
            /(dis)?agree(s|d|ment)?,? .*$me\s?\??/
        ) {
            # chat_question: Agree, disagree or be unsure with a question
            chat_question($channel) if module_enabled('chat_question');
        } default {
            if (/$me/i) {
                #chat_mention: Respond to name being used
                chat_mention($channel) if module_enabled('chat_mention');
            }
        }
    }
    return;
}

sub irc_msg {
    my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
    my $poco_irc = $sender->get_heap();
    my $nick = (split /!/, $who)[0];

    if ($what =~ /^$cmdprefix/) {
        my @cmd = parse_command($what);
        if ($cmd[0] eq 'say') {
            $poco_irc->yield(privmsg => $cmd[1] => "@cmd[2..$#cmd]");
        }
    }
}

sub irc_ctcp_action {
    my ($sender, $heap, $who, $where, $what) = @_[SENDER, HEAP, ARG0 .. ARG2];
    my $poco_irc = $sender->get_heap();
    my $me = $poco_irc->nick_name;
    my $nick = (split /!/, $who)[0];
    my $channel = $where->[0];

    if ($what =~ /$me/i) {
        # chat_mention: Respond to name being used
        chat_mention($channel) if module_enabled('chat_mention');
    }
    return;
}

sub irc_join {
    my ($sender, $who, $where) = @_[SENDER, ARG0, ARG1];
    my $poco_irc = $sender->get_heap();
    my $nick = (split /!/, $who)[0];

    say $poco_irc->nick_name;
    if ($poco_irc->nick_name eq $nick) {
        # chat-joingreet: Greet channel
        chat_joingreet($where) if module_enabled('chat_joingreet');
    }
    return;
}

sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ("$event: ");

    for my $arg (@$args) {
        if (ref $arg eq 'ARRAY') {
            push(@output, '[' . join(', ', @$arg) . ']');
        }
        else {
            push(@output, "'$arg'");
        }
    }
    say "@output";
    return;
}

sub _stop {
    if ($should_respawn) {
        say 'Restarting...';
        exec "$0 $ARGV[0]";
    } else {
        exit 0;
    }
}

# TODO: move this to module-related shit
sub module_enabled {
    return 1;
}

sub parse_command {
    my @args = (split /\s/, shift);
    $args[0] =~ tr/!//d; # trim $cmdprefix
    return @args;
}

# TODO: Move repetative sql setup to function?
sub chat_joingreet {
    my $channel = shift;
    my $sql = 'SELECT * FROM chat_joingreet ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $href = $sth->fetchrow_hashref;
    if ($href->{action}) {
        $poco_irc->yield(ctcp => $channel => "ACTION $href->{phrase}");
    } else {
        $poco_irc->yield(privmsg => $channel => $href->{phrase});
    }
}

sub chat_mention {
    my $channel = shift;
    my $sql = 'SELECT * FROM chat_mention ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $href = $sth->fetchrow_hashref;
    if ($href->{action}) {
        $poco_irc->yield(ctcp => $channel => "ACTION $href->{phrase}");
    } else {
        $poco_irc->yield(privmsg => $channel => $href->{phrase});
    }
}

sub chat_question {
    my $channel = shift;
    my $sql = 'SELECT * FROM chat_question WHERE agree=' . int(rand(3)) . ' ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $href = $sth->fetchrow_hashref;
    if ($href->{action}) {
        $poco_irc->yield(ctcp => $channel => "ACTION $href->{phrase}");
    } else {
        $poco_irc->yield(privmsg => $channel => $href->{phrase});
    }
}

sub chat_badcmd {
    my $channel = shift;
    my $sql = 'SELECT * FROM chat_badcmd ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $href = $sth->fetchrow_hashref;
    if ($href->{action}) {
        $poco_irc->yield(ctcp => $channel => "ACTION $href->{phrase}");
    } else {
        $poco_irc->yield(privmsg => $channel => $href->{phrase});
    }
}

sub chat_trollxeno {
    # TODO: make clever use of alarm() to flood protect?
    my $channel = shift;
    my $sql = 'SELECT * FROM chat_trollxeno ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my $href = $sth->fetchrow_hashref;
    if ($href->{action}) {
        $poco_irc->yield(ctcp => $channel => "ACTION $href->{phrase}");
    } else {
        $poco_irc->yield(privmsg => $channel => $href->{phrase});
    }
}

sub cmd_encode {
    my ($algorithm, $input, $channel) = @_;

    unless (length $input) {
        chat_badcmd($channel);
        return '';
    }
    given($algorithm) {
        $input =~ tr[a-zA-Z][n-za-mN-ZA-M]  when 'rot13';
        $input = uc md5_hex($input)         when 'md5';
        $input = sha256_hex($input)         when 'sha256';
        $input = sha512_hex($input)         when 'sha512';
        $input = crc32_hex($input)          when 'crc32';
        $input = encode_base64($input)      when 'base64';
        default {
            chat_badcmd($channel);
            return '';
        }
    }
    return $input;
}

sub cmd_roulette {
    my ($heap, $channel, $nick) = @_;
    my $bullet = \$heap->{game}{roulette}{bullet};
    my $shot = \$heap->{game}{roulette}{shot};

    if ($$shot++ != $$bullet) {
        $poco_irc->yield(privmsg => $channel => "CLICK! Who's next?");
        return;
    } else {
        if ($poco_irc->is_channel_operator(
                $channel,
                $poco_irc->nick_name,
        )) {
            $poco_irc->yield(kick => $channel => $nick => "BANG! You died.");
        } else {
            $poco_irc->yield(privmsg => $channel => "BANG! $nick died.");
        }
        cmd_roulette_reload($heap, $channel);
    }
    return;
}

sub cmd_roulette_reload {
    my ($heap, $channel) = @_;

    $poco_irc->yield(ctcp => $channel => "ACTION loads a single round and spins the chamber");
    $heap->{game}{roulette}{bullet} = int(rand(6));
    $heap->{game}{roulette}{shot} = 0;
}

sub cmd_nguess {
    my ($heap, $channel, $nick, $guess) = @_;
    my $magicnum = \$heap->{game}{nguess}{magicnum};
    my $guessnum = \$heap->{game}{nguess}{guessnum};

    unless ($guess =~ /\d+/) {
        # TODO: Randomize these phrases
        $poco_irc->yield(privmsg => $channel => "$nick: Try a number...");
        return;
    }

    $$guessnum++;
    if ($guess == $$magicnum) {
        $poco_irc->yield(privmsg => $channel => "DING! $nick wins! It took a total of $$guessnum guesses.");
        $poco_irc->yield(privmsg => $channel => "I'm thinking of another number between 1-100 ...can you guess it?");
        $$magicnum = int(rand(100)) + 1;
        $$guessnum = 0;
    } elsif ($guess > $$magicnum) {
        $poco_irc->yield(privmsg => $channel => "$nick: Too high!");
    } elsif ($guess < $$magicnum) {
        $poco_irc->yield(privmsg => $channel => "$nick: Too low!");
    }
}

sub cmd_8ball {
    my ($channel, $nick) = @_;
    my $sql = 'SELECT * FROM magic_8ball WHERE not_question=0 ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my @row = $sth->fetchrow_array;
    $poco_irc->yield(privmsg => $channel => "$nick: $row[0]");
}

sub cmd_8ball_not_question {
    my ($channel, $nick) = @_;
    my $sql = 'SELECT * FROM magic_8ball WHERE not_question=1 ORDER BY RANDOM() LIMIT 1';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    my @row = $sth->fetchrow_array;
    $poco_irc->yield(privmsg => $channel => "$nick: $row[0]");
}

