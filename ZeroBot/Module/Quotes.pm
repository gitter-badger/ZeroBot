#!/usr/bin/env perl

package ZeroBot::Module::Quotes;

use v5.14;
use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(quote_recite quote_add quote_del quote_help quote_undo quote_getlast);

my $module_name = 'Quotes';

use POE;
use POSIX qw(strftime);
use ZeroBot::Module::BadCmd;

# TODO: Implement inclusive filtering by pattern, author, submitter, etc
sub quote_recite {
    my ($target, $sender, $author, $pattern, $submitter) = @_;
    my ($style, $quote);

    # '*' is syntactic sugar for '.*' in quote command (only if alone)
    $author = '.' if !$author or $author eq '*';
    $pattern = '.' if !$pattern or $pattern eq '*';
    my @ary = $main::dbh->selectrow_array(q{
        SELECT * FROM quotes
        WHERE author REGEXP ? AND phrase REGEXP ?
        ORDER BY RANDOM() LIMIT 1;
    }, undef, ("(?i:$author)", "(?i:$pattern)"));
    given ($ary[5]) {
        when (0) {
            $style = '';
            $quote = $ary[0];
        } when (1) {
            $style = "<$ary[1]>";
            $quote = join(' ', $style, $ary[0]);
        } when (2) {
            $style = "* $ary[1]";
            $quote = join(' ', $style, $ary[0]);
        } when (3) {
            $style = "- $ary[1]";
            $quote = join(' ', '"'.$ary[0].'"', $style);
        }
    }
    $main::irc->yield(privmsg => $target => $quote);
    quote_setlast('recite', $ary[1], $ary[0]);
}

sub quote_add {
    my ($target, $sender, $author, $phrase, $submitter, $style) = @_;

    my $quote;
    $style = 1 if !defined $style;
    my $rows = $main::dbh->do(q{
        INSERT INTO quotes (phrase, author, submitter, style, date, time)
        VALUES (?, ?, ?, ?, ?, ?)
    }, undef, ($phrase, $author, $submitter, $style, strftime("%F", localtime), strftime("%T", localtime)));

    given ($style) {
        when (0) {
            $quote = "$phrase";
        } when (1) {
            $quote = "<$author> $phrase";
        } when (2) {
            $quote = "* $author $phrase";
        } when (3) {
            $quote = "\"$phrase\" - $author";
        }
    }
    $main::irc->yield(privmsg => $target => "$sender: Okay, adding: $quote");
    quote_setlast('add', $author, $phrase);
}

sub quote_del {
    my ($target, $sender, $author, $phrase) = @_;

    my ($style, $quote);
    my @ary = $main::dbh->selectrow_array(q{
        SELECT * FROM quotes
        WHERE author=? AND phrase=?
    }, undef, ($author, $phrase));
    my $rows = $main::dbh->do(q{
        DELETE FROM quotes
        WHERE author=? AND phrase=?
    }, undef, ($author, $phrase));
    given ($ary[5]) {
        when (0) {
            $style = '';
            $quote = $ary[0];
        } when (1) {
            $style = "<$ary[1]>";
            $quote = join(' ', $style, $ary[0]);
        } when (2) {
            $style = "* $ary[1]";
            $quote = join(' ', $style, $ary[0]);
        } when (3) {
            $style = "- $ary[1]";
            $quote = join(' ', '"'.$ary[0].'"', $style);
        }
    }
    $main::irc->yield(privmsg => $target => "$sender: Okay, removing: $quote");
    quote_setlast('del', $ary[1], $ary[0]);
}

sub quote_help {
    my $target = shift;

    $main::irc->yield(privmsg => $target => "quote [author] [pattern] | Both arguments are perl-regex patterns. A lone '*' is equivalent to '.*' (match anything). If unspecified, '*' is implied.");
    $main::irc->yield(privmsg => $target => "quote -add [-style=<style>] <author> <phrase> ...");
    $main::irc->yield(privmsg => $target => "quote -del <author> <phrase> | When removing, <author> and <phrase> must be EXACT");
    $main::irc->yield(privmsg => $target => "quote -del -last | Will remove the last added OR recited quote");
    $main::irc->yield(privmsg => $target => "quote -undo | Undo the last quote command. Currently only supports undoing `add`");
    $main::irc->yield(privmsg => $target => "If <author> is more than one word, surround it in double quotes (\"). Ex: !quote -add \"foo bar\" foo!");
    $main::irc->yield(privmsg => $target => "`style` defines how the quote should be displayed, and can be any of the following (1 is implicit default):");
    $main::irc->yield(privmsg => $target => "   0: Only the quote itself is shown, no other formatting is applied. WYSIWYG.");
    $main::irc->yield(privmsg => $target => "   1: The author is prefixed to the quote. Ex: <foo> bar!");
    $main::irc->yield(privmsg => $target => "   2: Quote will be displayed as an ACTION. Ex: * foo bars about");
    $main::irc->yield(privmsg => $target => "   3: Elegant style. The quote is wrapped in '\"' and the author is appended to the quote following a hyphen. Ex: \"Bar.\" - foo");
}

sub quote_undo {
    my ($target, $sender) = @_;
    my $session = $poe_kernel->get_active_session();
    my $heap = $session->get_heap();
    my $lastcmd = $heap->{quote}{lastcmd};
    my @lastquote = @{ $heap->{quote}{lastquote} };

    foreach ($lastcmd) {
        when ('add') { # Remove last added quote
            quote_del($target, $sender, $lastquote[0], $lastquote[1]);
            quote_setlast('del', @lastquote);
        } default {
            badcmd($target);
        }
    }
}

sub quote_setlast {
    my $session = $poe_kernel->get_active_session();
    my $heap = $session->get_heap();

    $heap->{quote}{lastcmd} = shift;
    @{ $heap->{quote}{lastquote} } = @_;
}

sub quote_getlast {
    my $session = $poe_kernel->get_active_session();
    my $heap = $session->get_heap();

    return %{ $heap->{quote} }
}

1;
