#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Telegram::Claude::Manager;

sub capture_run {
    my ( $code_ref ) = @_;
    my $stdout = q{};
    my $stderr = q{};
    open my $out_fh, '>', \$stdout or die $!;
    open my $err_fh, '>', \$stderr or die $!;
    my $rc = $code_ref->( $out_fh, $err_fh );
    return ( $rc, $stdout, $stderr );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => {},
            );
            return $manager->main_install();
        }
    );
    is( $rc, 2, 'main_install returns usage failure without token' );
    is( $stdout, q{}, 'main_install usage error keeps stdout empty' );
    like( $stderr, qr/TELEGRAM_BOT_TOKEN is required/, 'main_install explains missing token' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                get_runner => sub {
                    return { ok => JSON::XS::true, result => { username => 'jamesthexe_bot' } };
                },
            );
            return $manager->main_get_me();
        }
    );
    is( $rc, 0, 'main_get_me succeeds' );
    is( $stderr, q{}, 'main_get_me leaves stderr empty on success' );
    is( decode_json($stdout)->{username}, 'jamesthexe_bot', 'main_get_me prints JSON payload' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                get_runner => sub {
                    return {
                        ok     => JSON::XS::true,
                        result => [
                            {
                                update_id => 14,
                                message   => {
                                    message_id => 3,
                                    text       => 'hello',
                                    chat       => { id => 88, type => 'private' },
                                },
                            },
                        ],
                    };
                },
            );
            return $manager->main_updates( 10, 1, 0 );
        }
    );
    is( $rc, 0, 'main_updates succeeds' );
    is( $stderr, q{}, 'main_updates leaves stderr empty' );
    is( decode_json($stdout)->{count}, 1, 'main_updates prints summarised updates JSON' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                post_runner => sub {
                    my ( $method, $params ) = @_;
                    return { ok => JSON::XS::true, result => { message_id => 44, chat => { id => $params->{chat_id} }, text => $params->{text} } };
                },
            );
            return $manager->main_reply( 77, 'hi', 'bot' );
        }
    );
    is( $rc, 0, 'main_reply succeeds' );
    is( decode_json($stdout)->{text}, 'hi bot', 'main_reply prints reply JSON' );
    is( $stderr, q{}, 'main_reply leaves stderr empty' );
}

{
    my $cwd = '/tmp/telegram-claude-cli-download';
    mkdir $cwd if !-d $cwd;
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                cwd             => $cwd,
                stdout_fh       => $out_fh,
                stderr_fh       => $err_fh,
                env             => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                get_runner      => sub {
                    my ( $method ) = @_;
                    return { ok => JSON::XS::true, result => { file_path => 'docs/report.txt' } } if $method eq 'getFile';
                    die "unexpected method $method";
                },
                download_runner => sub { return 'HELLO'; },
            );
            return $manager->main_download('file-9');
        }
    );
    unlink "$cwd/downloads/report.txt" if -f "$cwd/downloads/report.txt";
    rmdir "$cwd/downloads" if -d "$cwd/downloads";
    rmdir $cwd if -d $cwd;
    is( $rc, 0, 'main_download succeeds' );
    is( $stderr, q{}, 'main_download leaves stderr empty' );
    is( decode_json($stdout)->{bytes}, 5, 'main_download prints download result JSON' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
            );
            return $manager->main_send_photo( 77, '/definitely/missing.png' );
        }
    );
    is( $rc, 2, 'main_send_photo fails for missing file' );
    is( $stdout, q{}, 'main_send_photo missing file keeps stdout empty' );
    like( $stderr, qr/Photo path does not exist/, 'main_send_photo explains missing photo' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
            );
            return $manager->main_send_audio( 77, '/definitely/missing.mp3' );
        }
    );
    is( $rc, 2, 'main_send_audio fails for missing file' );
    is( $stdout, q{}, 'main_send_audio missing file keeps stdout empty' );
    like( $stderr, qr/Audio path does not exist/, 'main_send_audio explains missing audio' );
}

{
    my $tmpfile = '/tmp/telegram-claude-cli-document.txt';
    open my $fh, '>', $tmpfile or die $!;
    print {$fh} 'doc';
    close $fh or die $!;
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh   => $out_fh,
                stderr_fh   => $err_fh,
                env         => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                post_runner => sub {
                    my ( $method, $params, $files ) = @_;
                    return {
                        ok     => JSON::XS::true,
                        result => {
                            message_id => 45,
                            chat       => { id => $params->{chat_id} },
                            caption    => $params->{caption},
                            file       => $files->{document},
                        },
                    };
                },
            );
            return $manager->main_send_document( 77, $tmpfile, 'hello', 'doc' );
        }
    );
    unlink $tmpfile or die $!;
    is( $rc, 0, 'main_send_document succeeds' );
    is( $stderr, q{}, 'main_send_document leaves stderr empty' );
    is( decode_json($stdout)->{caption}, 'hello doc', 'main_send_document prints document result JSON' );
}

{
    my $tmpfile = '/tmp/telegram-claude-cli-audio.mp3';
    open my $fh, '>', $tmpfile or die $!;
    print {$fh} 'audio';
    close $fh or die $!;
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh   => $out_fh,
                stderr_fh   => $err_fh,
                env         => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                post_runner => sub {
                    my ( $method, $params, $files ) = @_;
                    return {
                        ok     => JSON::XS::true,
                        result => {
                            message_id => 46,
                            chat       => { id => $params->{chat_id} },
                            caption    => $params->{caption},
                            file       => $files->{audio},
                        },
                    };
                },
            );
            return $manager->main_send_audio( 77, $tmpfile, 'hello', 'audio' );
        }
    );
    unlink $tmpfile or die $!;
    is( $rc, 0, 'main_send_audio succeeds' );
    is( $stderr, q{}, 'main_send_audio leaves stderr empty' );
    is( decode_json($stdout)->{caption}, 'hello audio', 'main_send_audio prints audio result JSON' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                cwd            => '/tmp/telegram-claude-e2e-workspace',
                home           => tempdir( CLEANUP => 1 ),
                stdout_fh      => $out_fh,
                stderr_fh      => $err_fh,
                env            => { WORKSPACE_REF => 'telegram-e2e' },
                command_runner => sub {
                    my ( $command, $meta ) = @_;
                    return {
                        command   => [ @{$command} ],
                        exit_code => 0,
                        stdout    => $command->[-1] eq 'ps' ? q{} : q{},
                    };
                },
            );
            return $manager->main_e2e('start');
        }
    );
    is( $rc, 0, 'main_e2e start succeeds' );
    is( $stderr, q{}, 'main_e2e start leaves stderr empty' );
    is( decode_json($stdout)->{status}, 'started', 'main_e2e start prints the e2e start JSON payload' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh            => $out_fh,
                stderr_fh            => $err_fh,
                env                  => { VERSION => '0.25' },
                claude_version_runner => sub { return "2.1.0 (Claude Code)\n"; },
            );
            return $manager->main_start('--version');
        }
    );
    is( $rc, 0, 'main_start --version succeeds' );
    is( $stderr, q{}, 'main_start --version leaves stderr empty' );
    is( $stdout, "2.1.0 (Claude Code)\n", 'main_start --version proxies the real claude version output DD expects' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh   => $out_fh,
                stderr_fh   => $err_fh,
                env         => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
                get_runner  => sub {
                    return {
                        ok     => JSON::XS::true,
                        result => [ { update_id => 21, message => { message_id => 8, text => '/start', chat => { id => 55 } } } ],
                    };
                },
                post_runner => sub {
                    my ( $method, $params ) = @_;
                    return { ok => JSON::XS::true, result => { message_id => 60, chat => { id => $params->{chat_id} } } };
                },
            );
            return $manager->main_auto_reply_start('hello from bot');
        }
    );
    is( $rc, 0, 'main_auto_reply_start succeeds' );
    is( $stderr, q{}, 'main_auto_reply_start leaves stderr empty' );
    is( decode_json($stdout)->{checked}, 1, 'main_auto_reply_start prints JSON result' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $runtime, 'cli-pair' );
    make_path($workspace);
    my $manager = Telegram::Claude::Manager->new(
        cwd       => $workspace,
        home      => $runtime,
        env       => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $paths = $manager->listener_paths_for_session('cli-pair');
    $manager->write_listener_pairing_state(
        $paths,
        {
            pending_chat_id => 88,
            pairing_code    => 'deadbeefcafebabe',
        },
    );
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                cwd       => $workspace,
                home      => $runtime,
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => {
                    TELEGRAM_BOT_TOKEN         => 'token-xyz',
                    TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
                },
            );
            return $manager->main_pair('deadbeefcafebabe');
        }
    );
    is( $rc, 0, 'main_pair succeeds for the pending challenge code' );
    is( $stderr, q{}, 'main_pair leaves stderr empty on success' );
    is( decode_json($stdout)->{paired_chat_id}, 88, 'main_pair prints the paired chat id' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => {
                    TICKET_REF                      => 'DD-276',
                    TELEGRAM_BOT_TOKEN              => 'token-xyz',
                    TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
                    TELEGRAM_CLAUDE_START_CAPTURE    => 1,
                    CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
                },
            );
            return $manager->main_start('--search');
        }
    );
    is( $rc, 0, 'main_start succeeds in capture mode' );
    is( $stderr, q{}, 'main_start leaves stderr empty' );
    is( decode_json($stdout)->{mode}, 'start', 'main_start prints the start JSON payload' );
}

{
    my ( $rc, $stdout, $stderr ) = capture_run(
        sub {
            my ( $out_fh, $err_fh ) = @_;
            my $runtime = tempdir( CLEANUP => 1 );
            my $manager = Telegram::Claude::Manager->new(
                stdout_fh => $out_fh,
                stderr_fh => $err_fh,
                env       => {
                    TELEGRAM_BOT_TOKEN         => 'token-xyz',
                    TELEGRAM_CLAUDE_DISABLE_PAIRING => 1,
                    TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
                    CLAUDE_SESSION_ID           => 'cli-listen',
                },
                get_runner => sub {
                    return {
                        ok     => JSON::XS::true,
                        result => [
                            {
                                update_id => 15,
                                message   => {
                                    message_id => 9,
                                    text       => 'hi listener',
                                    chat       => { id => 77, type => 'private' },
                                },
                            },
                        ],
                    };
                },
                post_runner => sub {
                    my ( $method, $params ) = @_;
                    return { ok => JSON::XS::true, result => { message_id => 61, chat => { id => $params->{chat_id} }, text => $params->{text} } };
                },
            );
            my $rc = $manager->main_check_message( 'cli-listen', 1, 0, 'listener online' );
            return $rc;
        }
    );
    is( $rc, 0, 'main_check_message succeeds' );
    is( $stderr, q{}, 'main_check_message leaves stderr empty' );
    is( decode_json($stdout)->{replied}, 1, 'main_check_message prints collector polling result JSON' );
    is( decode_json($stdout)->{session_id}, 'cli-listen', 'main_check_message reports the requested session suffix' );
    like( decode_json($stdout)->{offset_file}, qr{/listener\.offset\z}, 'main_check_message reports the shared poll offset path' );
}

done_testing;
