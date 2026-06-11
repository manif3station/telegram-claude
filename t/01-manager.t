#!/usr/bin/env perl
use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::XS qw(decode_json encode_json);
use POSIX ();
use Test::More;

use lib 'lib';
use Telegram::Claude::Manager;

{
    package TestResponse;
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }
    sub is_success      { return shift->{is_success} }
    sub decoded_content { return shift->{decoded_content} }
    sub status_line     { return shift->{status_line} || '500 fail' }
}

{
    package TestUA;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            request_queue => $args{request_queue} || [],
            get_queue     => $args{get_queue} || [],
        }, $class;
    }
    sub request {
        my ( $self, $request ) = @_;
        push @{ $self->{requests} }, $request;
        return shift @{ $self->{request_queue} };
    }
    sub get {
        my ( $self, @args ) = @_;
        push @{ $self->{gets} }, \@args;
        return shift @{ $self->{get_queue} };
    }
}

sub new_manager {
    my (%args) = @_;
    my $cwd = $args{cwd} || tempdir( CLEANUP => 1 );
    my %env = (
        TELEGRAM_CLAUDE_DISABLE_PAIRING => 1,
        %{ $args{env} || {} },
    );
    return Telegram::Claude::Manager->new(
        cwd             => $cwd,
        home            => $args{home} || $cwd,
        os              => $args{os},
        skill_root      => $args{skill_root},
        env             => \%env,
        stdout_fh       => $args{stdout_fh},
        stderr_fh       => $args{stderr_fh},
        get_runner      => $args{get_runner},
        post_runner     => $args{post_runner},
        download_runner => $args{download_runner},
        listener_start_runner => $args{listener_start_runner},
        listener_start_pid    => $args{listener_start_pid},
        sleep_runner         => $args{sleep_runner},
        claude_resume_runner  => $args{claude_resume_runner},
        claude_version_runner => $args{claude_version_runner},
        command_runner       => $args{command_runner},
        pid_check_runner     => $args{pid_check_runner},
        process_signal_runner => $args{process_signal_runner},
        typing_guard_runner  => $args{typing_guard_runner},
        progress_guard_runner => $args{progress_guard_runner},
        fork_runner          => $args{fork_runner},
        process_list_runner  => $args{process_list_runner},
        tmux_panes_runner    => $args{tmux_panes_runner},
        tmux_send_runner     => $args{tmux_send_runner},
        tmux_capture_runner  => $args{tmux_capture_runner},
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my @commands;
    my $manager = new_manager(
        cwd            => '/tmp/telegram-claude-e2e-workspace',
        home           => $home,
        env            => {
            WORKSPACE_REF => 'telegram-e2e',
        },
        command_runner => sub {
            my ( $command, $meta ) = @_;
            push @commands, [ @{$command} ];
            if ( $command->[-1] eq 'ps' ) {
                return {
                    command   => [ @{$command} ],
                    exit_code => 0,
                    stdout    => q{},
                };
            }
            return {
                command   => [ @{$command} ],
                exit_code => 0,
                stdout    => q{},
            };
        },
    );

    my $result = $manager->execute_e2e('start');
    is( $result->{mode}, 'e2e', 'execute_e2e start reports e2e mode' );
    is( $result->{action}, 'start', 'execute_e2e start reports start action' );
    is( $result->{status}, 'started', 'execute_e2e start reports started status' );
    is( $result->{novnc_port}, 25900, 'execute_e2e start uses the governed noVNC port' );
    is( $result->{chrome_debug_port}, 29222, 'execute_e2e start exposes the governed Chrome debug port' );
    is( $result->{chrome_profile_dir}, File::Spec->catdir( $home, '.developer-dashboard', 'state', 'telegram-claude', 'e2e', 'chrome-profile' ), 'execute_e2e start reports the persistent Chrome profile directory' );
    like( $result->{novnc_url}, qr{^http://127\.0\.0\.1:25900/}, 'execute_e2e start reports the noVNC URL' );
    ok( -f File::Spec->catfile( $home, '.developer-dashboard', 'state', 'telegram-claude', 'e2e', 'e2e.env' ), 'execute_e2e start writes the compose env file' );
    ok( -d File::Spec->catdir( $home, '.developer-dashboard', 'state', 'telegram-claude', 'e2e', 'chrome-profile' ), 'execute_e2e start creates the persistent Chrome profile directory' );
    my $env_file = $manager->read_text_file(
        File::Spec->catfile( $home, '.developer-dashboard', 'state', 'telegram-claude', 'e2e', 'e2e.env' )
    );
    like( $env_file, qr/^TELEGRAM_CLAUDE_E2E_HOST_UID=1000$/m, 'execute_e2e start defaults the runtime UID to 1000' );
    like( $env_file, qr/^TELEGRAM_CLAUDE_E2E_NOVNC_PORT=25900$/m, 'execute_e2e start persists the governed noVNC port' );
    like( $env_file, qr/^TELEGRAM_CLAUDE_E2E_CHROME_DEBUG_PORT=29222$/m, 'execute_e2e start persists the Chrome debug port' );
    my $expected_chrome_profile_dir = quotemeta(
        File::Spec->catdir( $home, '.developer-dashboard', 'state', 'telegram-claude', 'e2e', 'chrome-profile' )
    );
    like(
        $env_file,
        qr/^TELEGRAM_CLAUDE_E2E_CHROME_PROFILE_DIR=$expected_chrome_profile_dir$/m,
        'execute_e2e start persists the Chrome profile mount path',
    );
    is_deeply(
        \@commands,
        [
            [ 'docker', 'compose', '-f', $manager->e2e_compose_file, '--env-file', $manager->e2e_env_file, '-p', 'telegram-claude-e2e', 'build' ],
            [ 'docker', 'compose', '-f', $manager->e2e_compose_file, '--env-file', $manager->e2e_env_file, '-p', 'telegram-claude-e2e', 'down' ],
            [ 'docker', 'compose', '-f', $manager->e2e_compose_file, '--env-file', $manager->e2e_env_file, '-p', 'telegram-claude-e2e', 'up', '-d' ],
        ],
        'execute_e2e start runs the governed docker compose build/down/up sequence',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my @commands;
    my $manager = new_manager(
        cwd            => '/tmp/telegram-claude-e2e-workspace',
        home           => $home,
        env            => {
            WORKSPACE_REF => 'telegram-e2e',
        },
        command_runner => sub {
            my ( $command, $meta ) = @_;
            push @commands, [ @{$command} ];
            return {
                command   => [ @{$command} ],
                exit_code => 0,
                stdout    => $command->[-1] eq 'ps' ? "abc123\n" : q{},
            };
        },
    );

    $manager->write_text_file(
        $manager->e2e_state_file,
        $manager->encode_pretty_json(
            {
                project_name   => 'telegram-claude-e2e',
                workspace_path => '/tmp/telegram-claude-e2e-workspace',
                created_at     => '2026-06-03 17:00:00',
            }
        ),
    );
    $manager->write_text_file( $manager->e2e_env_file, "TELEGRAM_CLAUDE_E2E_NOVNC_PORT=25900\n" );

    my $result = $manager->execute_e2e('start');
    is( $result->{status}, 'already-running', 'execute_e2e start reports already-running when the stack is already up' );
    is_deeply(
        \@commands,
        [
            [ 'docker', 'compose', '-f', $manager->e2e_compose_file, '--env-file', $manager->e2e_env_file, '-p', 'telegram-claude-e2e', 'ps' ],
        ],
        'execute_e2e start only checks compose ps when the stack is already running',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my @commands;
    my $manager = new_manager(
        cwd            => '/tmp/telegram-claude-e2e-workspace',
        home           => $home,
        env            => {
            WORKSPACE_REF => 'telegram-e2e',
        },
        command_runner => sub {
            my ( $command, $meta ) = @_;
            push @commands, [ @{$command} ];
            return {
                command   => [ @{$command} ],
                exit_code => 0,
                stdout    => $command->[-1] eq 'ps' ? "abc123\n" : q{},
            };
        },
    );
    $manager->write_text_file( $manager->e2e_state_file, $manager->encode_pretty_json( { project_name => 'telegram-claude-e2e' } ) );
    $manager->write_text_file( $manager->e2e_env_file, "TELEGRAM_CLAUDE_E2E_NOVNC_PORT=25900\n" );
    my $result = $manager->execute_e2e('status');
    is( $result->{status}, 'running', 'execute_e2e status reports running when compose ps returns a container id' );
    is_deeply(
        \@commands,
        [
            [ 'docker', 'compose', '-f', $manager->e2e_compose_file, '--env-file', $manager->e2e_env_file, '-p', 'telegram-claude-e2e', 'ps' ],
        ],
        'execute_e2e status checks compose ps for the running stack',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my @commands;
    my $manager = new_manager(
        cwd            => '/tmp/telegram-claude-e2e-workspace',
        home           => $home,
        env            => {
            WORKSPACE_REF => 'telegram-e2e',
        },
        command_runner => sub {
            my ( $command, $meta ) = @_;
            push @commands, [ @{$command} ];
            return {
                command   => [ @{$command} ],
                exit_code => 0,
                stdout    => q{},
            };
        },
    );
    $manager->write_text_file( $manager->e2e_state_file, $manager->encode_pretty_json( { project_name => 'telegram-claude-e2e' } ) );
    $manager->write_text_file( $manager->e2e_env_file, "TELEGRAM_CLAUDE_E2E_NOVNC_PORT=25900\n" );
    my $result = $manager->execute_e2e('stop');
    is( $result->{status}, 'stopped', 'execute_e2e stop reports stopped status' );
    ok( !-f $manager->e2e_state_file, 'execute_e2e stop removes the state file' );
    ok( !-f $manager->e2e_env_file, 'execute_e2e stop removes the env file' );
    is_deeply(
        \@commands,
        [
            [ 'docker', 'compose', '-f', $manager->e2e_compose_file, '--env-file', $manager->e2e_env_file, '-p', 'telegram-claude-e2e', 'down' ],
        ],
        'execute_e2e stop runs compose down',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $marketplace = File::Spec->catfile( $home, '.claude', '.tmp', 'plugins', '.agents', 'plugins', 'marketplace.json' );
    make_path( File::Spec->catdir( $home, '.claude', '.tmp', 'plugins', '.agents', 'plugins' ) );
    my $manager = new_manager(
        home => $home,
        env  => {
            CLAUDE_PRIMARY_PLUGIN_ROOT      => '~/.claude/.tmp/plugins/plugins',
            CLAUDE_PRIMARY_MARKETPLACE_PATH => '~/.claude/.tmp/plugins/.agents/plugins/marketplace.json',
            CLAUDE_REAL_BIN                 => '/opt/claude/bin/claude-real',
            TELEGRAM_BOT_TOKEN             => 'token-123',
        },
    );
    my $result = $manager->execute_install('token-123');
    is( $result->{plugin}, 'telegram-claude', 'install returns plugin name' );
    my $plugin_dir = File::Spec->catdir( $home, '.claude', '.tmp', 'plugins', 'plugins', 'telegram-claude' );
    ok( -f File::Spec->catfile( $plugin_dir, '.claude-plugin', 'plugin.json' ), 'install writes plugin manifest' );
    ok( -f File::Spec->catfile( $plugin_dir, '.mcp.json' ), 'install writes mcp config' );
    ok( -f File::Spec->catfile( $plugin_dir, '.env' ), 'install writes plugin env file' );
    ok( -f File::Spec->catfile( $plugin_dir, 'scripts', 'telegram_mcp.py' ), 'install writes mcp server script' );
    is(
        $manager->read_text_file( File::Spec->catfile( $plugin_dir, 'scripts', 'telegram_mcp.py' ) ),
        $manager->read_text_file( File::Spec->catfile( $manager->{skill_root}, 'scripts', 'telegram_mcp.py' ) ),
        'install copies the standalone plugin python script from the skill repo instead of embedding it inside Perl',
    );
    my $market_data = decode_json( $manager->read_text_file($marketplace) );
    is( $market_data->{plugins}[0]{name}, 'telegram-claude', 'install registers plugin in marketplace' );
    is( $result->{claude_wrapper}{real_claude_path}, '/opt/claude/bin/claude-real', 'install records the wrapped real claude binary path' );
    my $wrapper_path = $result->{claude_wrapper}{wrapper_path};
    my $dashboard_launcher_path = $result->{claude_wrapper}{dashboard_launcher_path};
    my $start_cli_path = File::Spec->catfile( $manager->{skill_root}, 'cli', 'start' );
    ok( -f $wrapper_path, 'install writes the claude command wrapper into the user PATH' );
    ok( -f $dashboard_launcher_path, 'install writes the dashboard claude launcher' );
    my $wrapper = $manager->read_text_file($wrapper_path);
    my $dashboard_launcher = $manager->read_text_file($dashboard_launcher_path);
    like( $wrapper, qr/exec "\Q$dashboard_launcher_path\E" "\$@"/, 'wrapper hands off into the dashboard claude launcher' );
    like( $wrapper, qr/telegram-claude-managed-claude-wrapper/, 'wrapper is marked as telegram-claude-managed' );
    like( $dashboard_launcher, qr/\Q$start_cli_path\E/, 'dashboard launcher targets the skill-owned cli/start entrypoint directly' );
    unlike( $dashboard_launcher, qr/dashboard telegram-claude\.start/, 'dashboard launcher no longer depends on dashboard dotted helper dispatch' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            CLAUDE_REAL_BIN => '/opt/claude/bin/claude-real',
            PATH           => join( q{:}, File::Spec->catdir( $home, '.local', 'bin' ), '/usr/bin' ),
        },
    );
    my $result = $manager->auto_setup;
    is( $result->{mode}, 'auto_setup', 'auto_setup reports its mode' );
    ok( -f File::Spec->catfile( $home, '.local', 'bin', 'claude' ), 'auto_setup provisions the claude wrapper without requiring plugin install' );
    ok( -f File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'claude' ), 'auto_setup provisions the dashboard claude launcher too' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $perl_bin = File::Spec->catdir( $home, 'perl5', 'bin' );
    make_path($perl_bin);
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        os   => 'MSWin32',
        env  => {
            PATH => join( q{;}, $perl_bin, 'C:\\Windows\\System32' ),
        },
    );
    is( $manager->select_claude_wrapper_dir, $perl_bin, 'select_claude_wrapper_dir prefers ~/perl5/bin on Windows when it participates in PATH' );
    my $paths = $manager->claude_launcher_paths;
    is( $paths->{wrapper_path}, File::Spec->catfile( $perl_bin, 'claude.cmd' ), 'claude_launcher_paths uses a .cmd wrapper on Windows' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $perl_bin = File::Spec->catdir( $home, 'perl5', 'bin' );
    make_path($perl_bin);
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        os   => 'MSWin32',
        env  => {
            PATH => join( q{;}, $perl_bin, 'C:\\Windows\\System32' ),
        },
    );
    my $result = $manager->auto_setup;
    is( $result->{mode}, 'auto_setup', 'Windows auto_setup still reports its mode when no real claude binary exists yet' );
    ok( -f File::Spec->catfile( $perl_bin, 'claude.cmd' ), 'Windows auto_setup provisions the PATH wrapper with a .cmd suffix' );
    ok( -f File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'claude' ), 'Windows auto_setup still provisions the dashboard claude launcher' );
    ok( !defined $result->{claude_wrapper}{real_claude_path}, 'Windows auto_setup leaves the real claude path unset when claude is not installed yet' );
    my $wrapper = $manager->read_text_file( File::Spec->catfile( $perl_bin, 'claude.cmd' ) );
    my $dashboard_launcher_path = File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'claude' );
    like( $wrapper, qr/perl "\Q$dashboard_launcher_path\E" %\*/, 'Windows wrapper hands off to the managed Perl launcher through cmd syntax' );
    my $dashboard_launcher = $manager->read_text_file( File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'claude' ) );
    like( $dashboard_launcher, qr/telegram-claude-managed-dashboard-claude-launcher/, 'Windows dashboard launcher keeps the managed marker' );
    like( $dashboard_launcher, qr/cli(?:\/|\\\\)start/, 'Windows dashboard launcher calls the skill cli/start entrypoint directly' );
}

{
    my $manager = new_manager(
        env        => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
        get_runner => sub {
            my ( $method, $params ) = @_;
            is( $method, 'getMe', 'get-me uses Telegram getMe' );
            is_deeply( $params, {}, 'get-me sends no params' );
            return {
                ok     => JSON::XS::true,
                result => { username => 'jamesthexe_bot', first_name => 'James (Executor)' },
            };
        },
    );
    my $result = $manager->execute_get_me;
    is( $result->{username}, 'jamesthexe_bot', 'get-me returns bot username' );
}

{
    my $manager = new_manager(
        env        => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
        get_runner => sub {
            my ( $method, $params ) = @_;
            is( $method, 'getUpdates', 'updates uses getUpdates' );
            is_deeply( $params, { offset => 10, limit => 5, timeout => 0 }, 'updates forwards optional parameters' );
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 91,
                        message   => {
                            message_id => 7,
                            text       => 'hello',
                            chat       => { id => 99, type => 'private' },
                            photo      => [ { file_id => 'small' }, { file_id => 'big' } ],
                            document   => { file_id => 'doc-1', file_name => 'report.pdf' },
                        },
                    },
                ],
            };
        },
    );
    my $result = $manager->execute_updates( 10, 5, 0 );
    is( $result->{count}, 1, 'updates returns count' );
    is( $result->{updates}[0]{photo}{file_id}, 'big', 'updates keeps the largest photo' );
    is( $result->{updates}[0]{document}{file_name}, 'report.pdf', 'updates returns document metadata' );
    is( $result->{next_offset}, 92, 'updates returns next offset' );
}

{
    my $cwd = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd             => $cwd,
        env             => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
        get_runner      => sub {
            my ( $method, $params ) = @_;
            is( $method, 'getFile', 'download first resolves getFile' );
            is( $params->{file_id}, 'file-123', 'download forwards file id' );
            return { ok => JSON::XS::true, result => { file_path => 'documents/report.pdf' } };
        },
        download_runner => sub {
            my ($url) = @_;
            like( $url, qr{/documents/report\.pdf$}, 'download fetches telegram file path' );
            return 'PDFDATA';
        },
    );
    my $result = $manager->execute_download('file-123');
    ok( -f File::Spec->catfile( $cwd, 'downloads', 'report.pdf' ), 'download writes file locally' );
    is( $result->{bytes}, 7, 'download reports byte length' );
}

{
    my @calls;
    my $manager = new_manager(
        env         => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
        post_runner => sub {
            my ( $method, $params, $files ) = @_;
            push @calls, [ $method, $params, $files ];
            return { ok => JSON::XS::true, result => { message_id => 12, chat => { id => $params->{chat_id} }, text => $params->{text}, caption => $params->{caption} } };
        },
    );
    my $reply = $manager->execute_reply( 55, 'hello', 'there' );
    is( $reply->{text}, 'hello there', 'reply joins trailing text arguments' );
    my $tmpdir = tempdir( CLEANUP => 1 );
    my $photo = File::Spec->catfile( $tmpdir, 'photo.png' );
    my $audio = File::Spec->catfile( $tmpdir, 'sound.mp3' );
    my $doc = File::Spec->catfile( $tmpdir, 'note.txt' );
    _write( $photo, 'png' );
    _write( $audio, 'mp3' );
    _write( $doc, 'doc' );
    $manager->execute_send_photo( 55, $photo, 'look', 'here' );
    $manager->execute_send_audio( 55, $audio, 'listen', 'here' );
    $manager->execute_send_document( 55, $doc, 'read', 'this' );
    is( $calls[1][0], 'sendPhoto', 'send-photo uses sendPhoto' );
    is( $calls[1][2]{photo}, $photo, 'send-photo forwards file path to multipart helper' );
    is( $calls[2][0], 'sendAudio', 'send-audio uses sendAudio' );
    is( $calls[2][2]{audio}, $audio, 'send-audio forwards file path to multipart helper' );
    is( $calls[3][0], 'sendDocument', 'send-document uses sendDocument' );
    is( $calls[3][2]{document}, $doc, 'send-document forwards file path to multipart helper' );
}

{
    my @post_calls;
    my @get_calls;
    my $manager = new_manager(
        env         => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
        get_runner  => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => [
                    { update_id => 10, message => { message_id => 5, text => '/start', chat => { id => 88 } } },
                    { update_id => 11, message => { message_id => 6, text => 'not-start', chat => { id => 88 } } },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => { message_id => 22, chat => { id => $params->{chat_id} } } };
        },
    );
    my $result = $manager->execute_auto_reply_start;
    is( $result->{checked}, 2, 'auto-reply-start inspects recent updates' );
    is( scalar @{ $result->{replied} }, 1, 'auto-reply-start replies once for /start' );
    is( $post_calls[0][0], 'sendMessage', 'auto-reply-start sends a message reply' );
    is( $get_calls[-1][1]{offset}, 12, 'auto-reply-start acknowledges updates with next offset' );
}

{
    my $manager = new_manager;
    ok( !defined $manager->listener_slash_command_name( { text => 'hello there' } ), 'listener_slash_command_name returns undef for ordinary non-slash Telegram text' );
    is( $manager->listener_slash_command_name( { text => '/status' } ), 'status', 'listener_slash_command_name parses a simple Telegram slash command' );
    is( $manager->listener_slash_command_name( { text => " \n/status \n" } ), 'status', 'listener_slash_command_name trims surrounding whitespace and newline noise before parsing a Telegram slash command' );
    is( $manager->listener_slash_command_name( { text => '/status@jamesthexe_bot extra words' } ), 'status', 'listener_slash_command_name strips the Telegram bot suffix and trailing arguments' );
    is( $manager->listener_slash_command_name( { text => "\t/help\t" } ), 'help', 'listener_slash_command_name still recognizes another supported slash command after surrounding whitespace normalization' );
    is( $manager->listener_help_reply, "Supported Telegram slash commands:\n/help\n/status", 'listener_help_reply lists the supported Telegram slash commands' );
    ok( !defined $manager->listener_slash_command_reply( { text => 'hello there' } ), 'listener_slash_command_reply returns undef for ordinary non-slash Telegram text' );
    is( $manager->listener_slash_command_reply( { text => '/help' } ), "Supported Telegram slash commands:\n/help\n/status", 'listener_slash_command_reply returns the help text for /help' );
    is( $manager->listener_slash_command_reply( { text => '/unknown' } ), "Unsupported Telegram slash command: /unknown\nSupported commands:\n/help\n/status", 'listener_slash_command_reply rejects unsupported Telegram slash commands explicitly' );
    my $status = $manager->listener_status_reply( $manager->listener_paths_for_session('skills') );
    like( $status, qr/\AClaude \/status unavailable\.\n/, 'listener_status_reply reports an explicit unavailable message when no live Claude pane exists' );
    like( $status, qr/No live tmux-backed Claude TUI pane is attached/, 'listener_status_reply explains that live tmux-backed Claude is required for /status parity' );
}

{
    my @sent;
    my @captures = (
        join(
            "\n",
            '╭─────────────────────────────────────────────────────────────────────────────────────────╮',
            '│  Model:                       gpt-5.4 (reasoning medium, summaries auto)                │',
            '│  Directory:                   ~/projects/developer-dashboard                            │',
            '│  Permissions:                 Full Access                                               │',
            '│  Agents.md:                   AGENTS.override.md                                        │',
            '│  Account:                     cereals.bedpost.0r@icloud.com (Pro)                       │',
            '│  Collaboration mode:          Default                                                   │',
            '│  Session:                     session-status-visible                                    │',
            '│                                                                                         │',
            '│  Context window:              27% left (193K used / 258K)                               │',
            '│  5h limit:                    [███████████████████░] 94% left (resets 10:23)            │',
            '│  Weekly limit:                [██████░░░░░░░░░░░░░░] 30% left (resets 19:40 on 26 May)  │',
            '╰─────────────────────────────────────────────────────────────────────────────────────────╯',
        ) . "\n",
    );
    my $manager = new_manager(
        env => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-visible',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 71,
                    tty    => 'pts/17',
                    etimes => 4,
                    cmd    => 'claude --resume session-status-visible',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%17',
                    tty             => '/dev/pts/17',
                    current_command => 'node',
                },
            ];
        },
        tmux_send_runner => sub {
            my ( $pane_id, $text ) = @_;
            push @sent, [ $pane_id, $text ];
            return 1;
        },
        tmux_capture_runner => sub {
            my ($pane_id) = @_;
            is( $pane_id, '%17', 'listener_status_reply checks the cached live pane capture first when it already resolves to a live Claude pane' );
            return $captures[0];
        },
    );
    my $status = $manager->listener_status_reply( $manager->listener_paths_for_session('skills') );
    is_deeply( \@sent, [], 'listener_status_reply does not reinject /status when the live pane already shows the real Claude status panel' );
    like( $status, qr/Session:\s+session-status-visible/, 'listener_status_reply returns the already-visible live Claude /status block without needing another slash-command injection' );
}

{
    my @sent;
    my @captures = (
        "before prompt\n",
        "before prompt\n",
        join(
            "\n",
            '╭─────────────────────────────────────────────────────────────────────────────────────────╮',
            '│  Model:                       gpt-5.4 (reasoning medium, summaries auto)                │',
            '│  Directory:                   ~/projects/developer-dashboard                            │',
            '│  Permissions:                 Full Access                                               │',
            '│  Agents.md:                   AGENTS.override.md                                        │',
            '│  Account:                     cereals.bedpost.0r@icloud.com (Pro)                       │',
            '│  Collaboration mode:          Default                                                   │',
            '│  Session:                     session-status-77                                         │',
            '│                                                                                         │',
            '│  Context window:              27% left (193K used / 258K)                               │',
            '│  5h limit:                    [███████████████████░] 94% left (resets 10:23)            │',
            '│  Weekly limit:                [██████░░░░░░░░░░░░░░] 30% left (resets 19:40 on 26 May)  │',
            '╰─────────────────────────────────────────────────────────────────────────────────────────╯',
        ) . "\n",
    );
    my $manager = new_manager(
        env => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-77',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 77,
                    tty    => 'pts/7',
                    etimes => 4,
                    cmd    => 'claude --resume session-status-77',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%7',
                    tty             => '/dev/pts/7',
                    current_command => 'node',
                },
            ];
        },
        tmux_send_runner => sub {
            my ( $pane_id, $text ) = @_;
            push @sent, [ $pane_id, $text ];
            return 1;
        },
        tmux_capture_runner => sub {
            my ($pane_id) = @_;
            is( $pane_id, '%7', 'live /status capture targets the resolved tmux pane' );
            return shift @captures;
        },
        sleep_runner => sub { return 0.1; },
    );
    my $status = $manager->listener_status_reply( $manager->listener_paths_for_session('skills') );
    is_deeply( \@sent, [ [ '%7', '/status' ] ], 'listener_status_reply injects /status into the live Claude tmux pane when the session is attached' );
    like( $status, qr/Model:\s+gpt-5\.4/, 'listener_status_reply returns the live Claude /status model line when a live tmux pane is available' );
    like( $status, qr/Session:\s+session-status-77/, 'listener_status_reply returns the live Claude /status session line when a live tmux pane is available' );
    like( $status, qr/Weekly limit:\s+\[██████/, 'listener_status_reply returns the live Claude /status limits block when a live tmux pane is available' );
}

{
    my @sent;
    my %captures = (
        '%2' => [
            "before status\n",
            "before status\n",
            join(
                "\n",
                'after status',
                '╭─────────────────────────────────────────────────────────────────────────────────────────╮',
                '│  Model:                       gpt-5.4 (reasoning medium, summaries auto)                │',
                '│  Directory:                   ~/projects/skills                                         │',
                '│  Session:                     session-status-99                                         │',
                '╰─────────────────────────────────────────────────────────────────────────────────────────╯',
            ) . "\n",
        ],
    );
    my $manager = new_manager(
        env => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-99',
        },
        process_list_runner => sub {
            return [
                { pid => 92, tty => 'pts/2', etimes => 1, cmd => 'claude --resume session-status-99' },
            ];
        },
        tmux_panes_runner => sub {
            return [
                { pane_id => '%2', tty => '/dev/pts/2', current_command => 'node' },
            ];
        },
        tmux_send_runner => sub {
            my ( $pane_id, $text ) = @_;
            push @sent, [ $pane_id, $text ];
            return 1;
        },
        tmux_capture_runner => sub {
            my ($pane_id) = @_;
            my $queue = $captures{$pane_id} || [];
            return @$queue > 1 ? shift @{$captures{$pane_id}} : $queue->[0];
        },
        sleep_runner => sub { return 0.1; },
    );
    my $status = $manager->listener_status_reply( $manager->listener_paths_for_session('skills') );
    is_deeply( \@sent, [ [ '%2', '/status' ] ], 'listener_status_reply injects /status into the matching live Claude tmux pane for the target session' );
    like( $status, qr/Session:\s+session-status-99/, 'listener_status_reply returns the live status block when a live tmux pane matches the target session' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $paths;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-cache',
            CLAUDE_SESSION_ID               => 'skills',
        },
        process_list_runner => sub {
            return [
                { pid => 41, tty => 'pts/41', etimes => 8, cmd => 'claude --resume session-status-cache' },
                { pid => 42, tty => 'pts/42', etimes => 2, cmd => 'claude --resume session-status-cache' },
            ];
        },
        tmux_panes_runner => sub {
            return [
                { pane_id => '%41', tty => '/dev/pts/41', current_command => 'node' },
                { pane_id => '%42', tty => '/dev/pts/42', current_command => 'node' },
                { pane_id => '%99', tty => '/dev/pts/99', current_command => 'bash' },
            ];
        },
    );
    $paths = $manager->listener_paths_for_session('skills');
    is_deeply(
        [ $manager->resolve_claude_live_tmux_panes('session-status-cache') ],
        [ '%42', '%41' ],
        'resolve_claude_live_tmux_panes returns matching live pane ids in freshest-first order',
    );
    ok( $manager->tmux_pane_id_exists('%42'), 'tmux_pane_id_exists accepts a live pane id from the current pane list' );
    ok( !$manager->tmux_pane_id_exists('%404'), 'tmux_pane_id_exists rejects an unknown pane id' );
    is( $manager->read_listener_live_pane_id($paths), undef, 'read_listener_live_pane_id returns undef when no cached pane file exists' );
    is( $manager->write_listener_live_pane_id( $paths, '%41' ), $paths->{live_pane_file}, 'write_listener_live_pane_id stores the cached live pane id' );
    is( $manager->read_listener_live_pane_id($paths), '%41', 'read_listener_live_pane_id reloads the cached live pane id from runtime state' );
    is_deeply(
        [ $manager->listener_status_live_pane_candidates( 'session-status-cache', $paths ) ],
        [ '%41', '%42' ],
        'listener_status_live_pane_candidates prefers the cached pane id and then appends live matches without duplicates',
    );
    is( $manager->write_listener_live_pane_id( $paths, undef ), 1, 'write_listener_live_pane_id is a no-op success when no pane id is supplied' );
}

{
    my $manager = new_manager(
        env => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-88',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 88,
                    tty    => 'pts/8',
                    etimes => 5,
                    cmd    => 'claude --resume session-status-88',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%8',
                    tty             => '/dev/pts/8',
                    current_command => 'node',
                },
            ];
        },
        tmux_send_runner    => sub { return 1; },
        tmux_capture_runner => sub { return "no status here\n"; },
        sleep_runner        => sub { return 0.1; },
    );
    my $status = $manager->listener_status_reply( $manager->listener_paths_for_session('skills') );
    like( $status, qr/\AClaude \/status unavailable\.\n/, 'listener_status_reply reports explicit unavailability when live /status capture fails for the resolved pane' );
    like( $status, qr/session-status-88/, 'listener_status_reply names the target Claude session when live /status capture fails' );
}

{
    my $manager = new_manager;
    is( $manager->extract_claude_status_block(undef), undef, 'extract_claude_status_block returns undef for an undefined pane capture' );
    is( $manager->extract_claude_status_block("ordinary output\nwithout a status block\n"), undef, 'extract_claude_status_block returns undef when no Claude status block is present' );
    is( $manager->claude_status_block_line(undef), 0, 'claude_status_block_line rejects undefined lines' );
    is( $manager->claude_status_block_line(q{}), 1, 'claude_status_block_line keeps blank status spacing lines' );
    is( $manager->claude_status_block_line('Model: gpt-5.4'), 1, 'claude_status_block_line keeps known Claude status label lines' );
    is( $manager->claude_status_block_line('╰────'), 1, 'claude_status_block_line keeps non-alphanumeric box lines' );
    is( $manager->claude_status_block_line('prompt> hi there'), 0, 'claude_status_block_line rejects ordinary prompt content' );
    like(
        scalar $manager->extract_claude_status_block(
            "\n" . join(
                "\n",
                q{},
                '│  Model: gpt-5.4 │',
                '│  Session: abc-123 │',
                '╰────────╯',
                q{},
            ) . "\n",
        ),
        qr/\AModel:|^│  Model:/m,
        'extract_claude_status_block can recover a compact Claude status block from pane capture text',
    );
}

{
    my $manager = new_manager;
    like( scalar( eval { $manager->claude_live_status_snapshot( undef, '%9' ); 1 } ? q{} : $@ ), qr/Missing Claude session id/, 'claude_live_status_snapshot fails explicitly when the session id is missing' );
    like( scalar( eval { $manager->claude_live_status_snapshot( 'session-1', undef ); 1 } ? q{} : $@ ), qr/Missing tmux pane id/, 'claude_live_status_snapshot fails explicitly when the tmux pane id is missing' );
    like( scalar( eval { $manager->claude_live_status_reply( undef, '%9' ); 1 } ? q{} : $@ ), qr/Missing Claude session id/, 'claude_live_status_reply fails explicitly when the session id is missing' );
    like( scalar( eval { $manager->claude_live_status_reply( 'session-1', undef ); 1 } ? q{} : $@ ), qr/Missing tmux pane id/, 'claude_live_status_reply fails explicitly when the tmux pane id is missing' );
    like( scalar( eval { $manager->tmux_capture_pane_text(undef); 1 } ? q{} : $@ ), qr/Missing tmux pane id/, 'tmux_capture_pane_text fails explicitly when the tmux pane id is missing' );
    like( scalar( eval { $manager->tmux_send_text_to_pane( undef, '/status' ); 1 } ? q{} : $@ ), qr/Missing tmux pane id/, 'tmux_send_text_to_pane fails explicitly when the tmux pane id is missing' );
}

{
    my $manager = new_manager(
        tmux_capture_runner => sub { return "ordinary prompt\n"; },
    );
    is( $manager->claude_live_status_snapshot( 'session-snap-none', '%41' ), undef, 'claude_live_status_snapshot returns undef when the live pane does not currently contain a Claude status block' );
}

{
    my $manager = new_manager(
        tmux_capture_runner => sub {
            return join(
                "\n",
                '╭─────────────────────────────────────────────────────────────────────────────────────────╮',
                '│  Model:                       gpt-5.4 (reasoning medium, summaries auto)                │',
                '│  Session:                     session-snap-other                                         │',
                '╰─────────────────────────────────────────────────────────────────────────────────────────╯',
            ) . "\n";
        },
    );
    is( $manager->claude_live_status_snapshot( 'session-snap-target', '%42' ), undef, 'claude_live_status_snapshot returns undef when the visible status block belongs to a different Claude session' );
}

{
    my $manager = new_manager(
        tmux_capture_runner => sub {
            return join(
                "\n",
                '╭─────────────────────────────────────────────────────────────────────────────────────────╮',
                '│  Model:                       gpt-5.4 (reasoning medium, summaries auto)                │',
                '│  Session:                     some-other-session                                         │',
                '╰─────────────────────────────────────────────────────────────────────────────────────────╯',
            ) . "\n";
        },
    );
    is(
        $manager->claude_live_status_snapshot( 'session-1', '%9' ),
        undef,
        'claude_live_status_snapshot rejects a captured status block when it belongs to a different Claude session',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $runtime, 'bin' );
    make_path($bin_dir);
    my $tmux = File::Spec->catfile( $bin_dir, 'tmux' );
    _write(
        $tmux,
        <<'SH'
#!/bin/sh
if [ "$1" = "capture-pane" ] && [ "$2" = "-p" ] && [ "$3" = "-t" ] && [ "$4" = "%55" ]; then
  printf 'fake tmux status block\n'
  exit 0
fi
exit 1
SH
    );
    chmod 0755, $tmux or die "Unable to chmod fake tmux: $!";
    local $ENV{PATH} = $bin_dir;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            PATH => $bin_dir,
        },
    );
    is( $manager->tmux_capture_pane_text('%55'), "fake tmux status block\n", 'tmux_capture_pane_text can use the real shell-out capture path when a tmux binary is present on PATH' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $paths = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => { CLAUDE_SESSION_ID => 'skills' },
    )->listener_paths;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-cache',
            CLAUDE_SESSION_ID                 => 'skills',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 9,
                    tty    => 'pts/9',
                    etimes => 1,
                    cmd    => 'claude --resume session-status-cache',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%9',
                    tty             => '/dev/pts/9',
                    current_command => 'node',
                },
            ];
        },
    );
    make_path( $paths->{runtime_dir} );
    _write( $paths->{live_pane_file}, "%9\n" );
    is_deeply(
        [ $manager->listener_status_live_pane_candidates( 'session-status-cache', $paths ) ],
        ['%9'],
        'listener_status_live_pane_candidates reuses the cached live pane id when it still exists',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $paths = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => { CLAUDE_SESSION_ID => 'skills' },
    )->listener_paths;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-cache',
            CLAUDE_SESSION_ID                 => 'skills',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 9,
                    tty    => 'pts/9',
                    etimes => 1,
                    cmd    => 'claude --resume session-status-cache',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%9',
                    tty             => '/dev/pts/9',
                    current_command => 'node',
                },
            ];
        },
    );
    make_path( $paths->{runtime_dir} );
    _write( $paths->{live_pane_file}, "%404\n" );
    is_deeply(
        [ $manager->listener_status_live_pane_candidates( 'session-status-cache', $paths ) ],
        ['%9'],
        'listener_status_live_pane_candidates drops a cached pane id when that pane no longer exists',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-status-multi',
            CLAUDE_SESSION_ID                 => 'skills',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 99,
                    tty    => 'pts/9',
                    etimes => 1,
                    cmd    => 'claude --resume session-status-multi',
                },
                {
                    pid    => 98,
                    tty    => 'pts/9',
                    etimes => 2,
                    cmd    => 'claude --resume session-status-multi',
                },
                {
                    pid    => 97,
                    tty    => 'pts/10',
                    etimes => 3,
                    cmd    => 'claude --resume session-status-multi',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%9',
                    tty             => '/dev/pts/9',
                    current_command => 'node',
                },
                {
                    pane_id         => '%10',
                    tty             => '/dev/pts/10',
                    current_command => 'node',
                },
            ];
        },
    );
    is_deeply(
        [ $manager->resolve_claude_live_tmux_panes('session-status-multi') ],
        [ '%9', '%10' ],
        'resolve_claude_live_tmux_panes returns unique live tmux pane candidates for the target Claude session',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-abc',
        },
    );
    my $paths = $manager->listener_paths;
    is( $paths->{runtime_dir}, File::Spec->catdir( $runtime, 'session-abc' ), 'listener_paths partitions runtime state by CLAUDE_SESSION_ID' );
    is( $paths->{offset_file}, File::Spec->catfile( $runtime, 'session-abc', 'listener.offset' ), 'listener_paths stores offset under the session directory' );
    is( $paths->{inbox_file}, File::Spec->catfile( $runtime, 'session-abc', 'listener.inbox.jsonl' ), 'listener_paths stores inbox ledger under the session directory' );
    is( $paths->{pid_file}, File::Spec->catfile( $runtime, 'session-abc', 'listener.pid' ), 'listener_paths stores pid under the session directory' );
    is( $paths->{log_file}, File::Spec->catfile( $runtime, 'session-abc', 'listener.log' ), 'listener_paths stores log under the session directory' );
    is( $paths->{target_session_file}, File::Spec->catfile( $runtime, 'session-abc', 'claude.session' ), 'listener_paths stores the Claude target session under the session directory' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN           => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR   => $runtime,
            TELEGRAM_CLAUDE_SESSION_ID    => 'session-explicit',
            CLAUDE_SESSION_ID             => 'session-ignored',
        },
    );
    my $paths = $manager->listener_paths;
    is( $paths->{runtime_dir}, File::Spec->catdir( $runtime, 'session-explicit' ), 'listener_paths prefers TELEGRAM_CLAUDE_SESSION_ID when both session variables exist' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude' );
    _write( $real_claude, "#!/bin/sh\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake claude: $!";
    local $ENV{PATH} = $bin_dir;
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-xyz',
        },
    );
    my $paths = $manager->claude_launcher_paths;
    is( $manager->resolve_real_claude_bin($paths), $real_claude, 'resolve_real_claude_bin detects the current claude binary from PATH' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $tools_dir = File::Spec->catdir( $home, 'tools' );
    make_path($tools_dir);
    my $real_claude = File::Spec->catfile( $tools_dir, 'claude.cmd' );
    _write( $real_claude, "\@echo off\r\nexit /b 0\r\n" );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        os   => 'MSWin32',
        env  => {
            PATH    => $tools_dir,
            PATHEXT => '.COM;.EXE;.BAT;.CMD',
        },
    );
    my $paths = $manager->claude_launcher_paths;
    is( $manager->resolve_real_claude_bin($paths), $real_claude, 'resolve_real_claude_bin detects claude.cmd on Windows PATH entries' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $wrapper_root = File::Spec->catdir( $home, '.local', 'bin' );
    make_path($wrapper_root);
    my $wrapper_path = File::Spec->catfile( $wrapper_root, 'claude' );
    my $stored_real  = '/opt/claude/bin/claude-real';
    my $runtime_root = File::Spec->catdir( $home, '.telegram-claude' );
    make_path($runtime_root);
    _write( File::Spec->catfile( $runtime_root, '.claude-real-bin' ), "$stored_real\n" );
    _write( $wrapper_path, "#!/bin/sh\n# telegram-claude-managed-claude-wrapper\nexit 0\n" );
    chmod 0755, $wrapper_path or die "Unable to chmod stored wrapper: $!";
    local $ENV{PATH} = $wrapper_root;
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-xyz',
        },
    );
    my $paths = $manager->claude_launcher_paths;
    is( $manager->resolve_real_claude_bin($paths), $stored_real, 'resolve_real_claude_bin falls back to the stored real claude path when PATH resolves the wrapper itself' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $wrapper_root = File::Spec->catdir( $home, '.local', 'bin' );
    make_path($wrapper_root);
    local $ENV{PATH} = $wrapper_root;
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-xyz',
        },
    );
    my $paths = $manager->claude_launcher_paths;
    my $error = eval { $manager->resolve_real_claude_bin($paths); 1 } ? q{} : $@;
    like( $error, qr/Unable to resolve the real claude binary path/, 'resolve_real_claude_bin fails explicitly when no real claude binary path can be found' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
        },
    );
    my $plan = $manager->execute_start('--full-auto');
    is( $plan->{action}, 'exec', 'execute_start returns an exec plan when capture mode is enabled' );
    is_deeply( $plan->{claude_args}, ['--full-auto'], 'execute_start preserves direct claude args without a saved session mapping' );
    is( $plan->{start_collector}, 1, 'execute_start enables collector startup when autostart is enabled and a token is available' );
    is( $plan->{collector_session_id}, $manager->workspace_session_id, 'execute_start derives the collector session id from the workspace when no session env is present' );
    is( $plan->{collector_name}, 'telegram-claude-' . $manager->workspace_session_id, 'execute_start plans the DD collector name for the workspace session' );
    is( $plan->{collector_command}, 'dashboard telegram-claude.check-message ' . $manager->workspace_session_id, 'execute_start plans the session-suffixed collector command' );
    is( $plan->{claude_session_id}, $manager->workspace_session_id, 'execute_start plans Claude replies against the workspace session when nothing is mapped yet' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => File::Spec->catdir( $home, 'mt5-ai' ),
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
            CLAUDE_SESSION_ID                => 'skills',
        },
    );
    my $plan = $manager->execute_start;
    is( $plan->{workspace_session_id}, 'mt5-ai', 'execute_start derives the workspace session id from the current workspace name' );
    is( $plan->{collector_session_id}, 'mt5-ai', 'execute_start ignores ambient CLAUDE_SESSION_ID for collector ownership' );
    is( $plan->{claude_session_id}, 'mt5-ai', 'execute_start keeps the default Claude target aligned to the workspace session when there is no saved mapping' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => File::Spec->catdir( $home, 'mt5-ai' ),
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
            TELEGRAM_CLAUDE_SESSION_ID       => 'skills',
        },
    );
    my $plan = $manager->execute_start;
    is( $plan->{collector_session_id}, 'mt5-ai', 'execute_start ignores ambient TELEGRAM_CLAUDE_SESSION_ID for collector ownership' );
    is( $plan->{claude_session_id}, 'mt5-ai', 'execute_start keeps the default Claude target aligned to the workspace session when TELEGRAM_CLAUDE_SESSION_ID leaked from another workspace' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => File::Spec->catdir( $home, 'skills' ),
        home => $home,
        env  => {
            PWD                           => File::Spec->catdir( $home, 'websites' ),
            WORKSPACE_REF                 => 'skills',
            TICKET_REF                    => 'skills',
            CLAUDE_SESSION_ID              => 'skills',
            TELEGRAM_CLAUDE_SESSION_ID     => 'skills',
            TELEGRAM_BOT_TOKEN            => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE  => 1,
            CLAUDE_REAL_BIN                => '/opt/claude/bin/claude-real',
        },
    );
    my $plan = $manager->execute_start;
    is( $manager->workspace_session_id, 'websites', 'workspace_session_id prefers the shell PWD when DD dispatch cwd was retargeted by leaked workspace env' );
    is( $plan->{workspace_session_id}, 'websites', 'execute_start follows the shell PWD instead of leaked workspace env state' );
    is( $plan->{collector_session_id}, 'websites', 'execute_start keeps collector ownership on the shell-selected workspace when cwd and shell PWD diverge' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my @commands;
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            VERSION                         => '0.24',
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
        },
        command_runner => sub {
            my ($command) = @_;
            push @commands, [@$command];
            return { ok => 1 };
        },
    );
    my $result = $manager->execute_start('--version');
    is( $result->{mode}, 'start', 'execute_start --version reports start mode metadata' );
    is( $result->{action}, 'version', 'execute_start --version is a pure version query' );
    is( $result->{version}, '0.24', 'execute_start --version reports the skill version from env state' );
    ok( !exists $result->{collector_name}, 'execute_start --version does not build collector startup plan data' );
    is_deeply( \@commands, [], 'execute_start --version does not touch dashboard collector orchestration' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            VERSION => '0.25',
        },
        claude_version_runner => sub { return "2.1.0 (Claude Code)\n"; },
    );
    is( $manager->real_claude_version_output, "2.1.0 (Claude Code)\n", 'real_claude_version_output can proxy the underlying Claude CLI version string' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin = File::Spec->catfile( $home, 'claude-real-version' );
    _write( $bin, "#!/bin/sh\nprintf '2.1.0 (Claude Code)\\n'\n" );
    chmod 0755, $bin or die "Unable to chmod fake claude version binary: $!";
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            CLAUDE_REAL_BIN => $bin,
        },
    );
    is( $manager->real_claude_version_output, "2.1.0 (Claude Code)\n", 'real_claude_version_output can read the real Claude binary version output through the subprocess path' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin = File::Spec->catfile( $home, 'claude-real-empty-version' );
    _write( $bin, "#!/bin/sh\nexit 0\n" );
    chmod 0755, $bin or die "Unable to chmod fake empty claude version binary: $!";
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            CLAUDE_REAL_BIN => $bin,
        },
    );
    my $error = eval { $manager->real_claude_version_output; 1 } ? q{} : $@;
    like( $error, qr/Unexpected empty version output/, 'real_claude_version_output fails explicitly when the real Claude binary prints no version output' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'websites' );
    make_path($workspace);
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    _write(
        File::Spec->catfile( $config_root, 'claude.json' ),
        encode_json(
            {
                websites      => 'session-saved-77',
                skills        => 'session-leaked-11',
                _last_action  => 'Add websites',
                _last_update  => '2026-05-20 21:00:00',
            }
        ),
    );
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TICKET_REF                      => 'skills',
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
        },
    );
    my $plan = $manager->execute_start('--search');
    is_deeply( $plan->{claude_args}, [ '--resume', 'session-saved-77', '--search' ], 'execute_start preserves the original saved-session resume logic from the dashboard claude launcher' );
    is( $plan->{mapped_session}, 'session-saved-77', 'execute_start reports the mapped saved session id for the workspace path instead of the leaked ticket ref' );
    is( $plan->{collector_session_id}, $manager->workspace_session_id, 'execute_start still keeps the collector session keyed to the workspace session' );
    is( $plan->{claude_session_id}, 'session-saved-77', 'execute_start keeps Telegram replies pointed at the saved Claude session mapping' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    _write(
        File::Spec->catfile( $config_root, 'claude.json' ),
        encode_json(
            {
                'mt5-ai'    => 'session-saved-88',
                _last_action => 'Add mt5-ai',
                _last_update => '2026-05-21 19:00:00',
            }
        ),
    );
    my $workspace = File::Spec->catdir( $home, 'mt5-ai' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
        },
    );
    my $plan = $manager->execute_start( '--model', 'qwen3.5:397b-cloud', '--resume', 'session-saved-88' );
    is_deeply(
        $plan->{claude_args},
        [ '--model', 'qwen3.5:397b-cloud', '--resume', 'session-saved-88' ],
        'execute_start does not prepend another resume target when the incoming claude argv already carries one',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    _write(
        File::Spec->catfile( $config_root, 'config.json' ),
        encode_json(
            {
                collectors => [
                    { name => 'keep-me', interval => 10 },
                    { name => 'telegram-claude-demo', interval => 99, mode => 'multiple' },
                    { name => 'telegram-claude-demo', interval => 1, command => 'bad' },
                ],
            }
        ),
    );
    my $workspace = File::Spec->catdir( $home, 'demo' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
    );
    my $result = $manager->ensure_collector_config( 'demo', cwd => $workspace );
    is( $result->{collector_name}, 'telegram-claude-demo', 'ensure_collector_config targets the expected collector name' );
    is( $result->{removed_duplicates}, 1, 'ensure_collector_config removes duplicate collector entries for the same session' );
    my $saved = decode_json( $manager->read_text_file( File::Spec->catfile( $config_root, 'config.json' ) ) );
    my @telegram_collectors = grep { ref($_) eq 'HASH' && $_->{name} eq 'telegram-claude-demo' } @{ $saved->{collectors} };
    is( scalar @telegram_collectors, 1, 'ensure_collector_config leaves exactly one collector entry for the session' );
    is_deeply(
        $telegram_collectors[0],
        {
            name     => 'telegram-claude-demo',
            interval => 5,
            rotation => { lines => 100 },
            cwd      => $workspace,
            command  => 'dashboard telegram-claude.check-message demo',
            mode     => 'singleton',
        },
        'ensure_collector_config rewrites the collector to the governed telegram-claude collector shape',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    _write(
        File::Spec->catfile( $config_root, 'config.json' ),
        encode_json(
            {
                collectors => [
                    {
                        name     => 'telegram-claude-cwd-demo',
                        interval => 5,
                        rotation => { lines => 100 },
                        cwd      => '/tmp/old-workspace',
                        command  => 'dashboard telegram-claude.check-messages',
                        mode     => 'singleton',
                    },
                ],
            }
        ),
    );
    my $workspace = File::Spec->catdir( $home, 'new-workspace' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
    );
    my $result = $manager->ensure_collector_config( 'cwd-demo', cwd => $workspace );
    is( $result->{created}, 0, 'ensure_collector_config treats a same-name collector with the wrong cwd as an update, not a new collector' );
    my $saved = decode_json( $manager->read_text_file( File::Spec->catfile( $config_root, 'config.json' ) ) );
    is( $saved->{collectors}[0]{cwd}, $workspace, 'ensure_collector_config rewrites collector cwd when the existing entry points at a different workspace' );
    is( $saved->{collectors}[0]{command}, 'dashboard telegram-claude.check-message cwd-demo', 'ensure_collector_config rewrites the legacy plural collector command to the session-suffixed check-message form' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    my $workspace = File::Spec->catdir( $home, 'mt5-ai' );
    make_path($workspace);
    _write(
        File::Spec->catfile( $config_root, 'config.json' ),
        encode_json(
            {
                collectors => [
                    {
                        name     => 'telegram-claude-skills',
                        interval => 5,
                        rotation => { lines => 100 },
                        cwd      => $workspace,
                        command  => 'dashboard telegram-claude.check-message skills',
                        mode     => 'singleton',
                    },
                    {
                        name     => 'telegram-claude-mt5-ai',
                        interval => 5,
                        rotation => { lines => 100 },
                        cwd      => $workspace,
                        command  => 'dashboard telegram-claude.check-message mt5-ai',
                        mode     => 'singleton',
                    },
                ],
            }
        ),
    );
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
    );
    my $result = $manager->ensure_collector_config( 'mt5-ai', cwd => $workspace );
    is( $result->{removed_workspace_conflicts}, 1, 'ensure_collector_config removes stale telegram-claude collectors that still target the same workspace under the wrong session id' );
    my $saved = decode_json( $manager->read_text_file( File::Spec->catfile( $config_root, 'config.json' ) ) );
    my @telegram_collectors = grep { ref($_) eq 'HASH' && $_->{name} =~ /\Atelegram-claude-/ } @{ $saved->{collectors} };
    is( scalar @telegram_collectors, 1, 'ensure_collector_config leaves only the current workspace collector after healing a stale cross-session entry' );
    is( $telegram_collectors[0]{name}, 'telegram-claude-mt5-ai', 'ensure_collector_config keeps the governed collector for the current workspace session' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => File::Spec->catdir( $home, 'mt5-ai' ),
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_START_CAPTURE    => 1,
            TELEGRAM_CLAUDE_START_ACTIVE     => 1,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
        },
    );
    my $plan = $manager->execute_start;
    is( $plan->{start_collector}, 0, 'execute_start suppresses collector restart side effects when the managed start guard is already active in this process tree' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'mt5-ai' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN           => 'token-xyz',
            TELEGRAM_CLAUDE_START_CAPTURE => 1,
            TELEGRAM_CLAUDE_RUNTIME_DIR   => '~/.telegram-claude',
            CLAUDE_REAL_BIN               => '/opt/claude/bin/claude-real',
        },
    );
    my $plan = $manager->execute_start('--audit');
    my $audit_flag = File::Spec->catfile( $home, '.telegram-claude', $plan->{collector_session_id}, 'audit.enabled' );
    ok( -f $audit_flag, 'execute_start --audit persists the per-session audit flag for the collector-owned worker' );
    is( $manager->read_text_file($audit_flag), "1\n", 'execute_start --audit writes the enabled audit marker content' );
    is( $plan->{collector_session_id}, 'mt5-ai', 'execute_start --audit still captures the governed collector session id' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'workspace-collector' );
    make_path($workspace);
    my @commands;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        command_runner => sub {
            my ( $command, $meta ) = @_;
            push @commands, [ @$command, $meta->{plan}{collector_cwd}, $meta->{plan}{claude_session_id} ];
            return { ok => 1 };
        },
    );
    my $plan = {
        collector_session_id => 'workspace-collector',
        collector_name       => 'telegram-claude-workspace-collector',
        collector_cwd        => $workspace,
        claude_session_id     => 'session-saved-99',
    };
    $manager->ensure_startup_collector($plan);
    $manager->restart_startup_collector($plan);
    is_deeply(
        $commands[0],
        [ 'dashboard', 'restart', 'collector', 'telegram-claude-workspace-collector', $workspace, 'session-saved-99' ],
        'startup collector orchestration restarts the named DD collector after persisting the workspace session state',
    );
    is(
        $manager->read_claude_target_session_id(
            $manager->listener_paths_for_session('workspace-collector')->{target_session_file},
        ),
        'session-saved-99',
        'ensure_startup_collector persists the Claude target session used for future Telegram replies',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'workspace-restart-system' );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($workspace);
    make_path($bin_dir);
    my $dashboard = File::Spec->catfile( $bin_dir, 'dashboard' );
    my $log = File::Spec->catfile( $home, 'dashboard-restart.log' );
    _write( $dashboard, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$log\"\nexit 0\n" );
    chmod 0755, $dashboard or die "Unable to chmod fake dashboard restart helper: $!";
    local $ENV{PATH} = $bin_dir;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
    );
    my $result = $manager->restart_startup_collector(
        {
            collector_name => 'telegram-claude-workspace-restart-system',
        }
    );
    is( $result->{exit_code}, 0, 'restart_startup_collector succeeds through the real system command path' );
    my $restart_log = do {
        open my $fh, '<', $log or die $!;
        local $/;
        <$fh>;
    };
    is( $restart_log, "restart\ncollector\ntelegram-claude-workspace-restart-system\n", 'restart_startup_collector runs dashboard restart collector for the named session collector' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'workspace-stop-system' );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($workspace);
    make_path($bin_dir);
    my $dashboard = File::Spec->catfile( $bin_dir, 'dashboard' );
    my $log = File::Spec->catfile( $home, 'dashboard-stop.log' );
    _write( $dashboard, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$log\"\nexit 0\n" );
    chmod 0755, $dashboard or die "Unable to chmod fake dashboard stop helper: $!";
    local $ENV{PATH} = $bin_dir;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
    );
    my $result = $manager->stop_startup_collector('workspace-stop-system');
    is( $result->{exit_code}, 0, 'stop_startup_collector succeeds through the real system command path' );
    my $stop_log = do {
        open my $fh, '<', $log or die $!;
        local $/;
        <$fh>;
    };
    is( $stop_log, "stop\ncollector\ntelegram-claude-workspace-stop-system\n", 'stop_startup_collector runs dashboard stop collector for the named session collector' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    my @commands;
    my @signals;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
        command_runner => sub {
            my ($command) = @_;
            push @commands, [ @{$command} ];
            return { command => [ @{$command} ], exit_code => 0 };
        },
        pid_check_runner => sub { return $_[0] == 424242 ? 1 : 0 },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            return 1;
        },
        sleep_runner => sub { return 1; },
    );
    my $paths = $manager->listener_paths_for_session('skills');
    make_path( $paths->{runtime_dir} );
    _write( $paths->{pid_file}, "424242\n" );
    my $result = $manager->execute_stop;
    is( $result->{mode}, 'stop', 'execute_stop reports stop mode' );
    is( $result->{session_id}, 'skills', 'execute_stop targets the workspace session' );
    is( $result->{collector_name}, 'telegram-claude-skills', 'execute_stop reports the workspace collector name' );
    ok( $result->{recycled_worker}, 'execute_stop recycles the active workspace listener worker' );
    is_deeply(
        \@commands,
        [
            [ 'dashboard', 'stop', 'collector', 'telegram-claude-skills' ],
        ],
        'execute_stop uses the native DD stop collector command for the workspace collector',
    );
    is_deeply(
        \@signals,
        [
            [ 'TERM', 424242 ],
            [ 'KILL', 424242 ],
        ],
        'execute_stop recycles the active listener worker after stopping the DD collector',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    make_path($workspace);
    open my $stdout, '>', \my $stdout_buffer or die "Unable to open stdout buffer: $!";
    open my $stderr, '>', \my $stderr_buffer or die "Unable to open stderr buffer: $!";
    my @commands;
    my @signals;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
        stdout_fh => $stdout,
        stderr_fh => $stderr,
        command_runner => sub {
            my ($command) = @_;
            push @commands, [ @{$command} ];
            return { command => [ @{$command} ], exit_code => 0 };
        },
        pid_check_runner => sub { return $_[0] == 515151 ? 1 : 0 },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            return 1;
        },
        sleep_runner => sub { return 1; },
    );
    my $paths = $manager->listener_paths_for_session('skills');
    make_path( $paths->{runtime_dir} );
    _write( $paths->{pid_file}, "515151\n" );
    my $exit = $manager->main_stop;
    is( $exit, 0, 'main_stop exits cleanly' );
    my $result = decode_json($stdout_buffer);
    is( $result->{mode}, 'stop', 'main_stop prints stop mode JSON' );
    is( $result->{session_id}, 'skills', 'main_stop prints the workspace session id' );
    like( $stdout_buffer, qr/"collector_name"\s*:\s*"telegram-claude-skills"/, 'main_stop prints the workspace collector name' );
    is( defined $stderr_buffer ? $stderr_buffer : q{}, q{}, 'main_stop leaves stderr empty on success' );
    is_deeply(
        \@commands,
        [
            [ 'dashboard', 'stop', 'collector', 'telegram-claude-skills' ],
        ],
        'main_stop stops the workspace collector through the DD command',
    );
    is_deeply(
        \@signals,
        [
            [ 'TERM', 515151 ],
            [ 'KILL', 515151 ],
        ],
        'main_stop recycles the same-session listener worker',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    pipe( my $reader, my $writer ) or die "Unable to open overlap pipe: $!";
    my $child = fork();
    die "Unable to fork overlap-lock test: $!" if !defined $child;
    if ( !$child ) {
        close $reader;
        my $child_manager = new_manager(
            cwd  => $runtime,
            home => $runtime,
            env  => {
                TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            },
        );
        my $child_paths = $child_manager->listener_paths_for_session('session-overlap');
        make_path( $child_paths->{runtime_dir} );
        my $guard = $child_manager->begin_check_message_session( 'session-overlap', $child_paths );
        die "Child failed to hold overlap lock\n" if $guard->{already_running};
        print {$writer} "ready\n" or die "Unable to signal overlap child: $!";
        close $writer;
        sleep 10;
        POSIX::_exit(0);
    }
    close $writer;
    my $ready = <$reader>;
    close $reader;
    is( $ready, "ready\n", 'overlap child acquired the real session lock' );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $result = $manager->execute_check_messages( 'session-overlap', 1, 0 );
    is( $result->{skipped}, 1, 'execute_check_messages skips a second process when the same session suffix is already running' );
    is( $result->{running_pid}, $child, 'execute_check_messages reports the existing running pid for the same session suffix' );
    kill 'TERM', $child;
    waitpid $child, 0;
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $paths = $manager->listener_paths_for_session('session-stale-no-runner');
    $manager->write_text_file( $paths->{pid_file}, "999999\n" );
    my $guard = $manager->begin_check_message_session( 'session-stale-no-runner', $paths );
    is( $guard->{already_running}, 0, 'begin_check_message_session clears a stale pid file when the real process is gone' );
    is( $manager->read_text_file( $paths->{pid_file} ), "$$\n", 'begin_check_message_session replaces the stale pid file with the current worker pid' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $skills_paths = $manager->listener_paths_for_session('skills');
    my $web_paths = $manager->listener_paths_for_session('websites');
    make_path( $skills_paths->{runtime_dir} );
    make_path( $web_paths->{runtime_dir} );
    $manager->write_listener_pairing_state(
        $skills_paths,
        {
            paired_chat_id => 398296603,
            paired_at      => '2026-06-03 02:00:00',
        },
    );
    $manager->write_listener_pairing_state(
        $web_paths,
        {
            paired_chat_id => 398296603,
            paired_at      => '2026-06-02 02:00:00',
        },
    );
    my @cleared = $manager->enforce_unique_listener_pairing( 'skills', $skills_paths );
    is_deeply( \@cleared, ['websites'], 'enforce_unique_listener_pairing clears the same paired chat from other sessions' );
    my $web_state = $manager->read_listener_pairing_state($web_paths);
    ok( !exists $web_state->{paired_chat_id}, 'enforce_unique_listener_pairing removes the duplicate paired chat id from the other session' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $skills_paths = $manager->listener_paths_for_session('skills');
    my $web_paths = $manager->listener_paths_for_session('websites');
    make_path( $skills_paths->{runtime_dir} );
    make_path( $web_paths->{runtime_dir} );
    $manager->write_listener_pairing_state(
        $web_paths,
        {
            paired_chat_id => 398296603,
            paired_at      => '2026-06-03 02:00:00',
        },
    );
    my ( $target_session_id, $target_paths ) = $manager->listener_target_for_summary(
        {
            chat => { id => 398296603 },
        },
        'skills',
    );
    is( $target_session_id, 'websites', 'listener_target_for_summary routes an inbound Telegram chat to the paired session' );
    is( $target_paths->{runtime_dir}, $web_paths->{runtime_dir}, 'listener_target_for_summary returns the paired session runtime paths' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $skills_paths = $manager->listener_paths_for_session('skills');
    my $web_paths = $manager->listener_paths_for_session('websites');
    make_path( $skills_paths->{runtime_dir} );
    make_path( $web_paths->{runtime_dir} );
    $manager->write_listener_pairing_state(
        $web_paths,
        {
            pending_chat_id   => 398296603,
            pairing_code      => 'deadbeefcafebabe',
            challenge_sent_at => '2026-06-04 12:00:00',
        },
    );
    my ( $target_session_id, $target_paths ) = $manager->listener_target_for_summary(
        {
            chat => { id => 398296603 },
        },
        'skills',
    );
    is( $target_session_id, 'websites', 'listener_target_for_summary routes an inbound Telegram chat to the pending session that owns the current challenge' );
    is( $target_paths->{runtime_dir}, $web_paths->{runtime_dir}, 'listener_target_for_summary returns the pending session runtime paths' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $skills_paths = $manager->listener_paths_for_session('skills');
    my $web_paths = $manager->listener_paths_for_session('websites');
    make_path( $skills_paths->{runtime_dir} );
    make_path( $web_paths->{runtime_dir} );
    $manager->write_listener_pairing_claim(
        $manager->listener_shared_paths_for_session('skills'),
        {
            session_id => 'websites',
            claimed_at => '2026-06-04 12:05:00',
        },
    );
    my ( $target_session_id, $target_paths ) = $manager->listener_target_for_summary(
        {
            chat => { id => 398296603 },
        },
        'skills',
    );
    is( $target_session_id, 'websites', 'listener_target_for_summary routes an unpaired inbound Telegram chat to the claimed workspace session' );
    is( $target_paths->{runtime_dir}, $web_paths->{runtime_dir}, 'listener_target_for_summary returns the claimed workspace runtime paths' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $alpha_paths = $manager->listener_paths_for_session('alpha');
    my $beta_paths = $manager->listener_paths_for_session('beta');
    make_path( $alpha_paths->{runtime_dir} );
    make_path( $beta_paths->{runtime_dir} );
    $manager->write_listener_pairing_state(
        $alpha_paths,
        {
            paired_chat_id => 398296603,
            paired_at      => '2026-06-03 02:00:00',
        },
    );
    $manager->write_listener_pairing_state(
        $beta_paths,
        {
            paired_chat_id => 398296603,
            paired_at      => '2026-06-03 02:00:00',
        },
    );
    my ( $target_session_id, $target_paths ) = $manager->listener_target_for_summary(
        {
            chat => { id => 398296603 },
        },
        'skills',
    );
    is( $target_session_id, 'alpha', 'listener_target_for_summary uses the session id tie-break when paired_at matches' );
    is( $target_paths->{runtime_dir}, $alpha_paths->{runtime_dir}, 'listener_target_for_summary returns the tie-broken runtime paths' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $alpha_paths = $manager->listener_paths_for_session('alpha');
    my $beta_paths = $manager->listener_paths_for_session('beta');
    make_path( $alpha_paths->{runtime_dir} );
    make_path( $beta_paths->{runtime_dir} );
    $manager->write_listener_pairing_state(
        $alpha_paths,
        {
            pending_chat_id   => 398296603,
            pairing_code      => 'alpha-alpha-alpha1',
            challenge_sent_at => '2026-06-04 12:15:00',
        },
    );
    $manager->write_listener_pairing_state(
        $beta_paths,
        {
            pending_chat_id   => 398296603,
            pairing_code      => 'beta-beta-beta-22',
            challenge_sent_at => '2026-06-04 12:15:00',
        },
    );
    my ( $target_session_id, $target_paths ) = $manager->listener_target_for_summary(
        {
            chat => { id => 398296603 },
        },
        'skills',
    );
    is( $target_session_id, 'alpha', 'listener_target_for_summary uses the session id tie-break when pending challenge timestamps match' );
    is( $target_paths->{runtime_dir}, $alpha_paths->{runtime_dir}, 'listener_target_for_summary returns the pending-session tie-broken runtime paths' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'claim-defaults',
        },
    );
    my $claim = $manager->read_listener_pairing_claim;
    is_deeply( $claim, {}, 'read_listener_pairing_claim defaults to the current session shared paths' );
    $manager->write_listener_pairing_claim(
        undef,
        {
            session_id => 'claim-defaults',
            claimed_at => '2026-06-04 12:20:00',
        },
    );
    $claim = $manager->read_listener_pairing_claim;
    is( $claim->{session_id}, 'claim-defaults', 'write_listener_pairing_claim defaults to the current session shared paths' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-alpha',
        },
    );
    my $paths = $manager->listener_paths_for_session('skills');
    is(
        $paths->{runtime_root},
        File::Spec->catdir( $home, '.telegram-claude' ),
        'listener_paths_for_session keeps per-session runtime state under the shared ~/.telegram-claude root',
    );
    is(
        $manager->listener_shared_paths_for_session('skills')->{runtime_root},
        File::Spec->catdir( $home, '.telegram-claude', '.shared', Digest::SHA::sha1_hex('token-alpha') ),
        'listener_shared_paths_for_session isolates shared poll state by Telegram bot token',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $alpha = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-alpha',
        },
    );
    my $beta = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-beta',
        },
    );
    is(
        $alpha->listener_paths_for_session('skills')->{runtime_root},
        $beta->listener_paths_for_session('skills')->{runtime_root},
        'different Telegram bot tokens still share the same per-session runtime root contract',
    );
    isnt(
        $alpha->listener_shared_paths_for_session('skills')->{runtime_root},
        $beta->listener_shared_paths_for_session('skills')->{runtime_root},
        'different Telegram bot tokens get different shared poll roots',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => '~/custom-runtime',
            TELEGRAM_BOT_TOKEN         => 'token-alpha',
        },
    );
    is(
        $manager->listener_paths_for_session('skills')->{runtime_root},
        File::Spec->catdir( $home, 'custom-runtime' ),
        'explicit TELEGRAM_CLAUDE_RUNTIME_DIR still overrides the per-session runtime root',
    );
    is(
        $manager->listener_shared_paths_for_session('skills')->{runtime_root},
        File::Spec->catdir( $home, 'custom-runtime', '.shared', Digest::SHA::sha1_hex('token-alpha') ),
        'explicit TELEGRAM_CLAUDE_RUNTIME_DIR still scopes shared poll state by token under the configured runtime root',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {},
    );
    is(
        $manager->legacy_token_listener_runtime_root,
        File::Spec->catdir( $home, '.telegram-claude', 'default' ),
        'legacy_token_listener_runtime_root falls back to the default shared token root when no Telegram bot token is configured',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $legacy_runtime_root = File::Spec->catdir( $home, '.telegram-claude' );
    my $legacy_runtime_dir = File::Spec->catdir( $legacy_runtime_root, 'skills' );
    make_path($legacy_runtime_dir);
    _write( File::Spec->catfile( $legacy_runtime_dir, 'claude.session' ), "legacy-session-id\n" );
    _write( File::Spec->catfile( $legacy_runtime_dir, 'transcript.cursor' ), "41\n" );
    _write( File::Spec->catfile( $legacy_runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 707 } ) );
    _write( File::Spec->catfile( $legacy_runtime_root, 'listener.offset' ), "99\n" );
    _write( File::Spec->catfile( $legacy_runtime_root, 'pairing-claim.json' ), encode_json( { session_id => 'skills' } ) );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-alpha',
        },
    );
    ok( !$manager->ensure_listener_runtime_migrated('skills'), 'ensure_listener_runtime_migrated leaves already-flat session state untouched when only ambiguous flat shared poll files are present' );
    my $paths = $manager->listener_paths_for_session('skills');
    my $shared_paths = $manager->listener_shared_paths_for_session('skills');
    is( $paths->{runtime_dir}, File::Spec->catdir( $home, '.telegram-claude', 'skills' ), 'ensure_listener_runtime_migrated keeps session files under the flat session runtime directory' );
    is( $manager->read_text_file( $paths->{target_session_file} ), "legacy-session-id\n", 'ensure_listener_runtime_migrated preserves the legacy Claude session target file in the flat session runtime' );
    is( $manager->read_text_file( $paths->{transcript_cursor_file} ), "41\n", 'ensure_listener_runtime_migrated preserves the legacy transcript cursor file in the flat session runtime' );
    is( $manager->read_listener_pairing_state($paths)->{paired_chat_id}, 707, 'ensure_listener_runtime_migrated preserves the legacy pairing state file in the flat session runtime' );
    ok( !-f $shared_paths->{offset_file}, 'ensure_listener_runtime_migrated does not copy the ambiguous legacy flat shared listener offset into a token-scoped shared root' );
    ok( !-f $shared_paths->{inbox_file}, 'ensure_listener_runtime_migrated does not copy the ambiguous legacy flat shared listener inbox into a token-scoped shared root' );
    ok( !-f $shared_paths->{pairing_claim_file}, 'ensure_listener_runtime_migrated does not copy the ambiguous legacy flat shared pairing claim into a token-scoped shared root' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $token_root = File::Spec->catdir( $home, '.telegram-claude', Digest::SHA::sha1_hex('token-alpha') );
    my $token_runtime_dir = File::Spec->catdir( $token_root, 'skills' );
    make_path($token_runtime_dir);
    _write( File::Spec->catfile( $token_runtime_dir, 'claude.session' ), "token-scoped-session\n" );
    _write( File::Spec->catfile( $token_runtime_dir, 'transcript.cursor' ), "84\n" );
    _write( File::Spec->catfile( $token_runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 808 } ) );
    _write( File::Spec->catfile( $token_root, 'listener.offset' ), "199\n" );
    _write( File::Spec->catfile( $token_root, 'pairing-claim.json' ), encode_json( { session_id => 'skills' } ) );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-alpha',
        },
    );
    ok( $manager->ensure_listener_runtime_migrated('skills'), 'ensure_listener_runtime_migrated migrates the temporary token-scoped runtime back into the flat session runtime contract' );
    my $paths = $manager->listener_paths_for_session('skills');
    my $shared_paths = $manager->listener_shared_paths_for_session('skills');
    is( $manager->read_text_file( $paths->{target_session_file} ), "token-scoped-session\n", 'ensure_listener_runtime_migrated restores the claude session target from the token-scoped runtime' );
    is( $manager->read_text_file( $paths->{transcript_cursor_file} ), "84\n", 'ensure_listener_runtime_migrated restores the transcript cursor from the token-scoped runtime' );
    is( $manager->read_listener_pairing_state($paths)->{paired_chat_id}, 808, 'ensure_listener_runtime_migrated restores the pairing state from the token-scoped runtime' );
    is( $manager->read_text_file( $shared_paths->{offset_file} ), "199\n", 'ensure_listener_runtime_migrated restores the shared listener offset from the token-scoped runtime' );
    is( $manager->read_listener_pairing_claim($shared_paths)->{session_id}, 'skills', 'ensure_listener_runtime_migrated restores the shared pairing claim from the token-scoped runtime' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $legacy_runtime_root = File::Spec->catdir( $home, '.telegram-claude' );
    my $legacy_token_runtime_root = File::Spec->catdir( $home, '.telegram-claude', Digest::SHA::sha1_hex('token-alpha') );
    my $legacy_runtime_dir = File::Spec->catdir( $legacy_runtime_root, 'skills' );
    my $shared_runtime_dir = File::Spec->catdir( $legacy_runtime_root, '.shared', Digest::SHA::sha1_hex('token-alpha') );
    make_path($legacy_runtime_dir);
    make_path($shared_runtime_dir);
    make_path($legacy_token_runtime_root);
    _write( File::Spec->catfile( $legacy_runtime_dir, 'claude.session' ), "legacy-session-id\n" );
    _write( File::Spec->catfile( $legacy_runtime_root, 'listener.offset' ), "670028725\n" );
    _write( File::Spec->catfile( $legacy_runtime_root, 'listener.inbox.jsonl' ), "{\"update_id\":670028724}\n" );
    _write( File::Spec->catfile( $legacy_runtime_root, 'pairing-claim.json' ), encode_json( { session_id => 'mt5-ai' } ) );
    _write( File::Spec->catfile( $legacy_token_runtime_root, 'listener.offset' ), "670028725\n" );
    _write( File::Spec->catfile( $legacy_token_runtime_root, 'listener.inbox.jsonl' ), "{\"update_id\":670028724}\n" );
    _write( File::Spec->catfile( $legacy_token_runtime_root, 'pairing-claim.json' ), encode_json( { session_id => 'mt5-ai' } ) );
    _write( File::Spec->catfile( $shared_runtime_dir, 'listener.offset' ), "670028725\n" );
    _write( File::Spec->catfile( $shared_runtime_dir, 'listener.inbox.jsonl' ), "{\"update_id\":670028724}\n" );
    _write( File::Spec->catfile( $shared_runtime_dir, 'pairing-claim.json' ), encode_json( { session_id => 'mt5-ai' } ) );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-alpha',
        },
    );
    ok( $manager->ensure_listener_runtime_migrated('skills'), 'ensure_listener_runtime_migrated scrubs token roots that only contain copied flat shared poll state' );
    my $shared_paths = $manager->listener_shared_paths_for_session('skills');
    ok( !-f $shared_paths->{offset_file}, 'scrubbed copied flat shared offset from the token-scoped shared root' );
    ok( !-f $shared_paths->{inbox_file}, 'scrubbed copied flat shared inbox from the token-scoped shared root' );
    ok( !-f $shared_paths->{pairing_claim_file}, 'scrubbed copied flat shared pairing claim from the token-scoped shared root' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $legacy_runtime_root = File::Spec->catdir( $home, '.telegram-claude' );
    my $legacy_token_runtime_root = File::Spec->catdir( $home, '.telegram-claude', Digest::SHA::sha1_hex('token-alpha') );
    my $shared_runtime_dir = File::Spec->catdir( $legacy_runtime_root, '.shared', Digest::SHA::sha1_hex('token-alpha') );
    make_path($legacy_token_runtime_root);
    make_path($shared_runtime_dir);
    _write( File::Spec->catfile( $legacy_runtime_root, 'listener.offset' ), "670028725\n" );
    _write( File::Spec->catfile( $legacy_token_runtime_root, 'listener.offset' ), "165258875\n" );
    _write( File::Spec->catfile( $shared_runtime_dir, 'listener.offset' ), "670028725\n" );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN => 'token-alpha',
        },
    );
    ok( $manager->ensure_listener_runtime_migrated('skills'), 'ensure_listener_runtime_migrated restores token-attributable shared offsets over copied flat offsets' );
    my $shared_paths = $manager->listener_shared_paths_for_session('skills');
    is( $manager->read_text_file( $shared_paths->{offset_file} ), "165258875\n", 'restored the token-attributable shared offset into the current shared root' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    pipe( my $reader, my $writer ) or die "Unable to open poll-owner pipe: $!";
    my $child = fork();
    die "Unable to fork global-poll-lock test: $!" if !defined $child;
    if ( !$child ) {
        close $reader;
        my $child_manager = new_manager(
            cwd  => $runtime,
            home => $runtime,
            env  => {
                TELEGRAM_BOT_TOKEN         => 'token-xyz',
                TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            },
        );
        my $shared_paths = $child_manager->listener_shared_paths_for_session('owner-session');
        my $guard = $child_manager->begin_listener_global_poll_session( 'owner-session', $shared_paths );
        die "Child failed to hold global poll lock\n" if !$guard->{poll_owner};
        print {$writer} "ready\n" or die "Unable to signal poll owner child: $!";
        close $writer;
        sleep 10;
        POSIX::_exit(0);
    }
    close $writer;
    my $ready = <$reader>;
    close $reader;
    is( $ready, "ready\n", 'poll-owner child acquired the real global getUpdates lock' );
    my $process_tui_calls = 0;
    my $pause_calls = 0;
    local *Telegram::Claude::Manager::process_tui_live_outbound_transcript = sub {
        $process_tui_calls++;
        return 0;
    };
    local *Telegram::Claude::Manager::listener_pause_seconds = sub {
        $pause_calls++;
        return 0;
    };
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        get_runner => sub {
            die "getUpdates should not be called while another session owns the global poll lock\n";
        },
    );
    my $shared_paths = $manager->listener_shared_paths_for_session('skills');
    my $guard = $manager->begin_listener_global_poll_session( 'skills', $shared_paths );
    ok( !$guard->{poll_owner}, 'begin_listener_global_poll_session reports a non-owner guard when another session holds the shared bot-token poll lock' );
    my $owner_session_id = defined $guard->{owner_session_id} ? $guard->{owner_session_id} : q{};
    $owner_session_id =~ s/\s+\z//;
    is( $owner_session_id, 'owner-session', 'begin_listener_global_poll_session reports which session currently owns the shared bot-token poll lock' );
    is( $guard->{running_pid}, $child, 'begin_listener_global_poll_session reports the pid that currently owns the shared bot-token poll lock' );
    my $result = $manager->execute_check_messages( 'skills', 2, 0 );
    is( $result->{processed}, 0, 'execute_check_messages does not poll Telegram when another session owns the global getUpdates lock' );
    ok( $process_tui_calls >= 1, 'execute_check_messages still services TUI outbound transcript work while skipping Telegram polling' );
    ok( $pause_calls >= 1, 'execute_check_messages pauses and continues while another session owns the global getUpdates lock' );
    kill 'TERM', $child;
    waitpid $child, 0;
}

{
    my $manager = new_manager;
    ok( $manager->pid_is_running($$), 'pid_is_running uses the real kill-0 fallback when no test runner override is supplied' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'workspace-start-live' );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($workspace);
    make_path($bin_dir);
    my $args_file = File::Spec->catfile( $home, 'collector-start.args' );
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, "#!/bin/sh\nprintf '%s\\n' \"\$CLAUDE_SESSION_ID\" \"\$TELEGRAM_CLAUDE_SESSION_ID\" \"\$@\" > \"$args_file\"\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake real claude for collector start test: $!";
    my $command_log = File::Spec->catfile( $home, 'collector-restart.log' );
    my $pid = fork();
    die "Unable to fork execute_start collector branch test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $workspace,
            home => $home,
            env  => {
                TELEGRAM_BOT_TOKEN              => 'token-xyz',
                TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
                CLAUDE_REAL_BIN                  => $real_claude,
            },
            command_runner => sub {
                my ($command) = @_;
                _write( $command_log, join( "\n", @$command ) . "\n" );
                return { ok => 1 };
            },
        );
        $manager->execute_start('--search');
        exit 95;
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'execute_start runs the collector setup branch before launching the real claude binary' );
    my $restart_log = do {
        open my $fh, '<', $command_log or die $!;
        local $/;
        <$fh>;
    };
    is( $restart_log, "dashboard\nrestart\ncollector\ntelegram-claude-workspace-start-live\n", 'execute_start restarts the expected DD collector for the workspace session' );
    my $args = do {
        open my $fh, '<', $args_file or die $!;
        local $/;
        <$fh>;
    };
    is( $args, "workspace-start-live\nworkspace-start-live\n--dangerously-skip-permissions\n--search\n", 'execute_start exports the workspace session id and the managed bypass flag into the launched Claude process' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    make_path($workspace);
    my @signals;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
        pid_check_runner => sub { return $_[0] == 424242 ? 1 : 0 },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            return 1;
        },
        sleep_runner => sub { return 1; },
    );
    my $paths = $manager->listener_paths_for_session('skills');
    make_path( $paths->{runtime_dir} );
    _write( $paths->{pid_file}, "424242\n" );
    ok( $manager->recycle_check_message_session('skills'), 'recycle_check_message_session returns true when it finds and recycles an active per-session worker pid' );
    is_deeply( \@signals, [ [ 'TERM', 424242 ], [ 'KILL', 424242 ] ], 'recycle_check_message_session escalates from TERM to KILL when the worker still appears running' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
        pid_check_runner => sub { return 0 },
    );
    my $paths = $manager->listener_paths_for_session('skills');
    make_path( $paths->{runtime_dir} );
    _write( $paths->{pid_file}, "424242\n" );
    ok( !$manager->recycle_check_message_session('skills'), 'recycle_check_message_session returns false when it only clears a stale dead pid file' );
    ok( !-f $paths->{pid_file}, 'recycle_check_message_session removes the stale pid file when the recorded worker is already gone' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    make_path($workspace);
    my @signals;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 515151,
                    ppid   => 1,
                    tty    => '?',
                    etimes => 12,
                    cmd    => '/usr/bin/perl /tmp/telegram-claude-old/cli/check-message skills',
                },
                {
                    pid    => 616161,
                    ppid   => 1,
                    tty    => '?',
                    etimes => 11,
                    cmd    => '/usr/bin/perl /tmp/telegram-claude-old/cli/check-message skills',
                },
            ];
        },
        pid_check_runner => sub { return $_[0] == 616161 || $_[0] == 515151 ? 1 : 0 },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            return 1;
        },
        sleep_runner => sub { return 1; },
    );
    my $paths = $manager->listener_paths_for_session('skills');
    make_path( $paths->{runtime_dir} );
    _write( $paths->{pid_file}, "not-a-pid\n" );
    ok( $manager->recycle_check_message_session('skills'), 'recycle_check_message_session clears an invalid pid file and still recycles discovered same-session workers' );
    is_deeply(
        \@signals,
        [ [ 'TERM', 515151 ], [ 'KILL', 515151 ], [ 'TERM', 616161 ], [ 'KILL', 616161 ] ],
        'recycle_check_message_session unlinks invalid pid files before recycling discovered same-session workers in sorted pid order',
    );
    ok( !-f $paths->{pid_file}, 'recycle_check_message_session removes an invalid pid file before stale-worker recycle continues' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    make_path($workspace);
    my @signals;
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => File::Spec->catdir( $home, 'runtime-new' ),
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 515151,
                    ppid   => 1,
                    tty    => '?',
                    etimes => 12,
                    cmd    => '/usr/bin/perl /tmp/telegram-claude-old/cli/check-message skills',
                },
            ];
        },
        pid_check_runner => sub { return $_[0] == 515151 ? 1 : 0 },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            return 1;
        },
        sleep_runner => sub { return 1; },
    );
    ok( $manager->recycle_check_message_session('skills'), 'recycle_check_message_session still recycles a same-session worker discovered outside the current runtime pid file path' );
    is_deeply(
        \@signals,
        [ [ 'TERM', 515151 ], [ 'KILL', 515151 ] ],
        'recycle_check_message_session escalates against same-session stale workers discovered from the process table',
    );
}

{
    my $manager = new_manager;
    ok( $manager->signal_process( 0, $$ ), 'signal_process falls back to the real kill path when no test runner override is supplied' );
}

{
    my @signals;
    my $manager = new_manager(
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            return 0;
        },
    );
    ok( !$manager->signal_process( 'TERM', 999999 ), 'signal_process returns false when the override reports failure' );
    is_deeply( \@signals, [ [ 'TERM', 999999 ] ], 'signal_process forwards the signal and pid through the override runner' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'telegram-claude-e2e-workspace' );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($workspace);
    make_path($bin_dir);
    my $docker_bin = File::Spec->catfile( $bin_dir, 'docker-ps' );
    _write( $docker_bin, "#!/bin/sh\nprintf 'service-a\\nservice-b\\n'\n" );
    chmod 0755, $docker_bin or die "Unable to chmod fake docker ps binary: $!";
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_E2E_DOCKER_BIN => $docker_bin,
            WORKSPACE_REF                 => 'telegram-e2e',
        },
    );
    my $result = $manager->run_e2e_compose_command('ps');
    is_deeply(
        $result,
        {
            command   => [
                $docker_bin,
                'compose',
                '-f', $manager->e2e_compose_file,
                '--env-file', $manager->e2e_env_file,
                '-p', $manager->e2e_project_name,
                'ps',
            ],
            exit_code => 0,
            stdout    => "service-a\nservice-b\n",
        },
        'run_e2e_compose_command returns captured stdout for the real ps pipeline when no override runner is supplied',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'telegram-claude-e2e-workspace' );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($workspace);
    make_path($bin_dir);
    my $docker_bin = File::Spec->catfile( $bin_dir, 'docker-build' );
    _write( $docker_bin, "#!/bin/sh\nexit 0\n" );
    chmod 0755, $docker_bin or die "Unable to chmod fake docker build binary: $!";
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_E2E_DOCKER_BIN => $docker_bin,
            WORKSPACE_REF                 => 'telegram-e2e',
        },
    );
    my $result = $manager->run_e2e_compose_command('build');
    is_deeply(
        $result,
        {
            command   => [
                $docker_bin,
                'compose',
                '-f', $manager->e2e_compose_file,
                '--env-file', $manager->e2e_env_file,
                '-p', $manager->e2e_project_name,
                'build',
            ],
            exit_code => 0,
            stdout    => q{},
        },
        'run_e2e_compose_command returns the command metadata for successful real compose system calls',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => '/tmp/telegram-claude-e2e-workspace',
        home => $home,
        env  => {
            WORKSPACE_REF => 'telegram-e2e',
        },
    );
    local *CORE::GLOBAL::system = sub { return -1; };
    eval { $manager->run_e2e_compose_command('build') };
    like( $@, qr/^Command failed: docker compose /, 'run_e2e_compose_command dies when the raw system call fails' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'skills' );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($workspace);
    make_path($bin_dir);
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    my $args_file = File::Spec->catfile( $home, 'collector-recycle.args' );
    my $restart_log = File::Spec->catfile( $home, 'collector-recycle.restart' );
    my $recycle_log = File::Spec->catfile( $home, 'collector-recycle.called' );
    _write( $real_claude, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$args_file\"\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake real claude for recycle test: $!";
    my $pid = fork();
    die "Unable to fork execute_start recycle branch test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $workspace,
            home => $home,
            env  => {
                TELEGRAM_BOT_TOKEN              => 'token-xyz',
                TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
                CLAUDE_REAL_BIN                  => $real_claude,
            },
            command_runner => sub {
                my ($command) = @_;
                _write( $restart_log, join( "\n", @{$command} ) . "\n" );
                return { ok => 1 };
            },
        );
        no warnings 'redefine';
        local *Telegram::Claude::Manager::recycle_check_message_session = sub {
            my ( $self, $session_id ) = @_;
            _write( $recycle_log, "$session_id\n" );
            return 1;
        };
        $manager->execute_start('--search');
        exit 0;
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'execute_start succeeds after recycling an existing per-session check-message worker' );
    is( do { open my $fh, '<', $recycle_log or die $!; local $/; <$fh> }, "skills\n", 'execute_start invokes per-session worker recycling before restarting the collector' );
    is( do { open my $fh, '<', $restart_log or die $!; local $/; <$fh> }, "dashboard\nrestart\ncollector\ntelegram-claude-skills\n", 'execute_start still restarts the governed DD collector after recycling the old worker' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'websites' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TICKET_REF                   => 'skills',
            CLAUDE_REAL_BIN               => '/opt/claude/bin/claude-real',
            TELEGRAM_CLAUDE_START_CAPTURE => 1,
        },
    );
    my $result = $manager->execute_start( 'add', 'session-add-22' );
    is( $result->{action}, 'add', 'execute_start still supports add mode' );
    is( $result->{claude_session}, 'session-add-22', 'execute_start add mode preserves the saved-session management behavior' );
    my $saved = decode_json( $manager->read_text_file( File::Spec->catfile( $home, '.developer-dashboard', 'config', 'claude.json' ) ) );
    is( $saved->{websites}, 'session-add-22', 'execute_start add mode stores the mapping under the workspace session id' );
    ok( !exists $saved->{skills}, 'execute_start add mode does not store the mapping under a leaked ticket ref' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    _write(
        File::Spec->catfile( $config_root, 'claude.json' ),
        encode_json(
            {
                websites             => 'session-remove-44',
                'session-remove-44' => 'stale-marker',
            }
        ),
    );
    my $workspace = File::Spec->catdir( $home, 'websites' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TICKET_REF => 'skills',
        },
    );
    my $result = $manager->execute_start('remove');
    is( $result->{action}, 'remove', 'execute_start still supports remove mode' );
    is( $result->{claude_session}, 'session-remove-44', 'execute_start remove mode uses the saved session mapping' );
    my $saved = decode_json( $manager->read_text_file( File::Spec->catfile( $config_root, 'claude.json' ) ) );
    ok( !exists $saved->{'session-remove-44'}, 'execute_start remove mode preserves the original launcher deletion behavior for the saved session key' );
    ok( !exists $saved->{websites}, 'execute_start remove mode clears the workspace session mapping even when the ticket ref leaked from another workspace' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $listener_marker = File::Spec->catfile( $home, 'listener-child.log' );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_ENABLE_AUTOSTART => '1',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $home,
            CLAUDE_REAL_BIN                  => '/opt/claude/bin/claude-real',
        },
        listener_start_pid => 424242,
        listener_start_runner => sub {
            my ( $session_id, $paths, $options ) = @_;
            open my $fh, '>>', $listener_marker or die $!;
            print {$fh} "$session_id|$paths->{log_file}|$options->{mode}|$options->{claude_session_id}\n";
            close $fh or die $!;
        },
    );
    my $paths = $manager->start_listener_if_needed(
        'session-launch-88',
        mode             => 'claude-session',
        claude_session_id => 'session-launch-88',
    );
    ok( -f $paths->{pid_file}, 'start_listener_if_needed writes a pid file in the session runtime directory' );
    ok( defined $paths->{log_file} && $paths->{log_file} ne q{}, 'start_listener_if_needed returns the session log path' );
    is( $manager->read_text_file( $paths->{pid_file} ), "424242\n", 'start_listener_if_needed records the provided listener pid in test mode without forking a real listener' );
    my $marker = do {
        open my $fh, '<', $listener_marker or die $!;
        local $/;
        <$fh>;
    };
    like( $marker, qr/session-launch-88/, 'start_listener_if_needed runs the child listener startup path for the requested session' );
    like( $marker, qr/claude-session/, 'start_listener_if_needed passes the managed startup listener mode into the launch path' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $skill_root = File::Spec->catdir( $home, 'skill-root' );
    my $cli_dir = File::Spec->catdir( $skill_root, 'cli' );
    make_path($cli_dir);
    my $listen = File::Spec->catfile( $cli_dir, 'check-message' );
    _write( $listen, "#!/usr/bin/env perl\nsleep 30;\n" );
    chmod 0755, $listen or die "Unable to chmod fake running listener: $!";
    my $manager = new_manager(
        cwd        => $home,
        home       => $home,
        skill_root => $skill_root,
        env        => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
    );
    my $first = $manager->start_listener_if_needed('session-running-11');
    my $paths = $manager->start_listener_if_needed('session-running-11');
    is( $paths->{listener_running}, 1, 'start_listener_if_needed leaves an already-running session listener alone' );
    is( $paths->{pid}, $first->{pid}, 'start_listener_if_needed reports the existing running session listener pid' );
    kill 'TERM', $first->{pid};
    waitpid $first->{pid}, 0;
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $session_dir = File::Spec->catdir( $home, 'session-stale-11' );
    make_path($session_dir);
    _write( File::Spec->catfile( $session_dir, 'listener.pid' ), "999999\n" );
    my $listener_marker = File::Spec->catfile( $home, 'listener-stale.log' );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
        listener_start_pid => 515151,
        listener_start_runner => sub {
            my ( $session_id ) = @_;
            open my $fh, '>>', $listener_marker or die $!;
            print {$fh} "$session_id\n";
            close $fh or die $!;
        },
    );
    my $paths = $manager->start_listener_if_needed('session-stale-11');
    is( $manager->read_text_file( $paths->{pid_file} ), "515151\n", 'start_listener_if_needed replaces a stale pid file with the new listener pid' );
    my $marker = do {
        open my $fh, '<', $listener_marker or die $!;
        local $/;
        <$fh>;
    };
    is( $marker, "session-stale-11\n", 'start_listener_if_needed relaunches the listener after removing a stale pid file' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $skill_root = File::Spec->catdir( $home, 'skill-root' );
    my $cli_dir = File::Spec->catdir( $skill_root, 'cli' );
    make_path($cli_dir);
    my $listener_log = File::Spec->catfile( $home, 'listener.exec.log' );
    my $listen = File::Spec->catfile( $cli_dir, 'check-message' );
    _write( $listen, "#!/bin/sh\nprintf '%s\\n' \"\$TELEGRAM_CLAUDE_LISTENER_MODE\" \"\$TELEGRAM_CLAUDE_TARGET_SESSION_ID\" \"\$0\" \"\$@\" > \"$listener_log\"\n" );
    chmod 0755, $listen or die "Unable to chmod fake check-message command: $!";
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        skill_root => $skill_root,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
    );
    my $paths = $manager->start_listener_if_needed(
        'session-forked-22',
        mode             => 'claude-session',
        claude_session_id => 'session-forked-22',
        reply_text       => 'listener ack',
    );
    waitpid $paths->{pid}, 0 if $paths->{pid};
    for ( 1 .. 20 ) {
        last if -f $listener_log;
        select undef, undef, undef, 0.05;
    }
    my $exec_log = do {
        open my $fh, '<', $listener_log or die $!;
        local $/;
        <$fh>;
    };
    is( $exec_log, "claude-session\nsession-forked-22\n$listen\n0\n30\nlistener ack\n", 'start_listener_if_needed can fork and exec the skill-owned check-message command directly with managed session-response env' );
    is( $manager->listener_command_path, $listen, 'listener_command_path resolves the skill-owned check-message command' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $skill_root = File::Spec->catdir( $home, 'skill-root' );
    my $cli_dir = File::Spec->catdir( $skill_root, 'cli' );
    make_path($cli_dir);
    my $listen = File::Spec->catfile( $cli_dir, 'check-message' );
    _write( $listen, "#!/usr/bin/env perl\nsleep 30;\n" );
    chmod 0755, $listen or die "Unable to chmod sleeping fake check-message command: $!";
    my $manager = new_manager(
        cwd        => $home,
        home       => $home,
        skill_root => $skill_root,
        env        => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $home,
        },
    );
    my $first = $manager->start_listener_if_needed('session-singleton-22');
    ok( $first->{pid}, 'start_listener_if_needed returns a real listener pid for the first launch' );
    my $second = $manager->start_listener_if_needed('session-singleton-22');
    is( $second->{listener_running}, 1, 'start_listener_if_needed reuses the existing listener for the same session' );
    is( $second->{pid}, $first->{pid}, 'start_listener_if_needed returns the same resident listener pid for the same session' );
    kill 'TERM', $first->{pid};
    waitpid $first->{pid}, 0;
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $args_file = File::Spec->catfile( $home, 'real-claude.args' );
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$args_file\"\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake real claude: $!";
    my $pid = fork();
    die "Unable to fork execute_start real-claude test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $home,
            home => $home,
            env  => {
                CLAUDE_REAL_BIN => $real_claude,
            },
        );
        $manager->execute_start('--search');
        exit 91;
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'execute_start execs the real claude binary when no Ollama override is set' );
    my $args = do {
        open my $fh, '<', $args_file or die $!;
        local $/;
        <$fh>;
    };
    is( $args, "--dangerously-skip-permissions\n--search\n", 'execute_start prepends the bypass flag before forwarding direct claude args to the real claude binary' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $pid = fork();
    die "Unable to fork execute_start failure test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $home,
            home => $home,
            env  => {
                CLAUDE_REAL_BIN => File::Spec->catfile( $home, 'definitely-missing-claude' ),
            },
        );
        $manager->execute_start('--search');
        exit 94;
    }
    waitpid $pid, 0;
    isnt( $? >> 8, 94, 'execute_start reaches the post-exec failure path when the real claude binary cannot be launched' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $args_file = File::Spec->catfile( $home, 'ambient-ollama-ignored.args' );
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$args_file\"\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake real claude: $!";
    my $pid = fork();
    die "Unable to fork execute_start ambient ollama test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $home,
            home => $home,
            env  => {
                OLLAMA_MODEL  => '2',
                CLAUDE_REAL_BIN => $real_claude,
            },
        );
        $manager->execute_start('--search');
        exit 92;
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'execute_start ignores ambient OLLAMA_MODEL and still execs the real claude binary' );
    my $args = do {
        open my $fh, '<', $args_file or die $!;
        local $/;
        <$fh>;
    };
    is( $args, "--dangerously-skip-permissions\n--search\n", 'execute_start still prepends the bypass flag when ambient OLLAMA_MODEL is ignored' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $args_file = File::Spec->catfile( $home, 'explicit-ollama.args' );
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$args_file\"\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake real claude: $!";
    my $pid = fork();
    die "Unable to fork execute_start explicit ollama test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $home,
            home => $home,
            env  => {
                TELEGRAM_CLAUDE_OLLAMA_MODEL => '1',
                CLAUDE_REAL_BIN              => $real_claude,
            },
        );
        $manager->execute_start('--resume', 'session-x');
        exit 93;
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'execute_start supports the explicit Telegram-owned Ollama model branch' );
    my $args = do {
        open my $fh, '<', $args_file or die $!;
        local $/;
        <$fh>;
    };
    is( $args, "--model\nqwen3.5:397b-cloud\n--dangerously-skip-permissions\n--resume\nsession-x\n", 'execute_start injects the explicit Ollama Claude profile args and the bypass flag into the real Claude exec path' );
}

{
    my $manager = new_manager(
        env => {
            TELEGRAM_CLAUDE_OLLAMA_MODEL => 'llama3.3:70b',
        },
    );
    is( $manager->explicit_start_ollama_model, 'llama3.3:70b', 'explicit_start_ollama_model preserves an explicitly requested Telegram-owned Ollama model name' );
    is_deeply(
        [ $manager->inject_ollama_claude_args( 'llama3.3:70b', '--model', 'llama3.3:70b', '--resume', 'session-x' ) ],
        [ '--model', 'llama3.3:70b', '--resume', 'session-x' ],
        'inject_ollama_claude_args does not prepend another Ollama profile when the argv already targets the Ollama launch profile',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $args_file = File::Spec->catfile( $home, 'idempotent-bypass.args' );
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, "#!/bin/sh\nprintf '%s\\n' \"\$@\" > \"$args_file\"\nexit 0\n" );
    chmod 0755, $real_claude or die "Unable to chmod fake real claude idempotent target: $!";
    my $pid = fork();
    die "Unable to fork execute_start idempotent bypass test: $!" if !defined $pid;
    if ( !$pid ) {
        my $manager = new_manager(
            cwd  => $home,
            home => $home,
            env  => {
                CLAUDE_REAL_BIN => $real_claude,
            },
        );
        $manager->execute_start('--dangerously-skip-permissions', '--search');
        exit 93;
    }
    waitpid $pid, 0;
    is( $? >> 8, 0, 'execute_start leaves an already-present bypass flag idempotent' );
    my $args = do {
        open my $fh, '<', $args_file or die $!;
        local $/;
        <$fh>;
    };
    is( $args, "--dangerously-skip-permissions\n--search\n", 'execute_start does not duplicate the bypass flag when it is already present on the managed Claude argv' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $local_bin = File::Spec->catdir( $home, '.local', 'bin' );
    my $home_bin  = File::Spec->catdir( $home, 'bin' );
    make_path($local_bin);
    make_path($home_bin);
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            PATH => join( q{:}, $home_bin, $local_bin, '/usr/bin' ),
        },
    );
    is( $manager->select_claude_wrapper_dir, $home_bin, 'select_claude_wrapper_dir uses the first supported user PATH directory' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $local_bin = File::Spec->catdir( $home, '.local', 'bin' );
    my $home_bin  = File::Spec->catdir( $home, 'bin' );
    make_path($local_bin);
    make_path($home_bin);
    _write( File::Spec->catfile( $local_bin, 'claude' ), "#!/bin/sh\nexit 0\n" );
    _write( File::Spec->catfile( $home_bin,  'claude' ), "#!/bin/sh\nexit 0\n" );
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        env  => {
            PATH => join( q{:}, $local_bin, $home_bin, '/usr/bin' ),
        },
    );
    is( $manager->select_claude_wrapper_dir, $local_bin, 'select_claude_wrapper_dir falls back to the first supported candidate when all supported claude paths already exist' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @get_calls;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-listen',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 30,
                        message   => {
                            message_id => 10,
                            text       => 'hello',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                    {
                        update_id => 31,
                        message   => {
                            message_id => 11,
                            chat       => { id => 88, type => 'private' },
                            document   => { file_id => 'doc-9', file_name => 'report.pdf' },
                        },
                    },
                ],
            } if @get_calls == 1;
            return { ok => JSON::XS::true, result => [] };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 200 + scalar @post_calls, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $result = $manager->execute_listen( 2, 0, 'listener ack' );
    is( $result->{cycles}, 2, 'listen reports executed cycles' );
    is( $result->{processed}, 2, 'listen processes inbound updates' );
    is( $result->{replied}, 2, 'listen auto-replies to eligible messages' );
    is( $result->{next_offset}, 32, 'listen reports next offset' );
    is( $get_calls[0][1]{timeout}, 0, 'listen forwards poll timeout' );
    ok( !exists $get_calls[0][1]{offset}, 'listen omits offset before state exists' );
    is( $get_calls[1][1]{offset}, 32, 'listen resumes from persisted next offset on the next cycle' );
    is( scalar @post_calls, 2, 'listen sends a reply per eligible inbound message' );
    is( $post_calls[0][1]{reply_to_message_id}, 10, 'listen replies to original text message id' );
    is( $post_calls[1][1]{reply_to_message_id}, 11, 'listen replies to original document message id' );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    my $offset_file = File::Spec->catfile( $shared_root, 'listener.offset' );
    my $inbox_file  = File::Spec->catfile( $shared_root, 'listener.inbox.jsonl' );
    is( $manager->read_text_file($offset_file), "32\n", 'listen persists next offset to runtime state' );
    my @entries = split /\n/, $manager->read_text_file($inbox_file);
    is( scalar @entries, 2, 'listen appends inbound messages to inbox ledger' );
    is( decode_json( $entries[1] )->{document}{file_name}, 'report.pdf', 'listen logs document metadata in inbox ledger' );
    is( $result->{offset_file}, $offset_file, 'listen reports the shared poll offset path' );
    is( $result->{inbox_file}, File::Spec->catfile( $shared_root, 'listener.inbox.jsonl' ), 'listen reports the shared poll inbox path' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            CLAUDE_SESSION_ID                => 'session-managed-listen',
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-managed-listen',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 40,
                        message   => {
                            message_id => 12,
                            text       => 'hello2',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary ) = @_;
            push @resume_calls, [ $session_id, $prompt, $summary ];
            return 'This is a real Claude session reply.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 601, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $result = $manager->execute_listen( 1, 0 );
    is( $result->{processed}, 1, 'managed listener mode processes inbound Telegram messages' );
    is( $result->{replied}, 1, 'managed listener mode sends one reply after Claude generates it' );
    is( scalar @resume_calls, 1, 'managed listener mode resumes the active Claude session to generate the Telegram reply text' );
    is( $resume_calls[0][0], 'session-managed-listen', 'managed listener mode targets the active Claude session id' );
    like( $resume_calls[0][1], qr/text=hello2/, 'managed listener mode passes the inbound Telegram text into the Claude reply prompt' );
    is( $post_calls[0][0], 'sendChatAction', 'managed listener mode sends a typing action before the Claude-generated reply' );
    is( $post_calls[0][1]{action}, 'typing', 'managed listener mode uses Telegram typing status while the Claude reply is being generated' );
    like( $post_calls[1][1]{text}, qr/Claude verbose/, 'managed listener mode now opens the verbose trace before the final reply' );
    is( $post_calls[-2][1]{text}, 'This is a real Claude session reply.', 'managed listener mode sends the Claude-generated reply instead of a placeholder' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my @typing_events;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        typing_guard_runner => sub {
            my ( $summary, $self ) = @_;
            push @typing_events, 'guard-start';
            return sub {
                push @typing_events, 'guard-stop';
                return 1;
            };
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 101,
                        message   => {
                            message_id => 19,
                            text       => 'Hi',
                            chat       => { id => 99, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary ) = @_;
            push @typing_events, 'resume';
            push @resume_calls, [ $session_id, $prompt, $summary ];
            return 'Collector reply from Claude session.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            push @typing_events, 'send' if $method ne 'sendChatAction';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 777, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{session_id}, 'skills', 'collector-owned check-message keeps the explicit session suffix' );
    is( $result->{processed}, 1, 'collector-owned check-message processes inbound messages for the explicit session' );
    is( $result->{replied}, 1, 'collector-owned check-message auto-replies through the persisted Claude session target' );
    is( scalar @resume_calls, 1, 'collector-owned check-message resumes Claude exactly once' );
    is( $resume_calls[0][0], 'session-from-ledger', 'collector-owned check-message uses the persisted claude.session target for replies' );
    like( $resume_calls[0][1], qr/text=Hi/, 'collector-owned check-message passes the inbound text into the Claude reply prompt' );
    is( $post_calls[0][0], 'sendChatAction', 'collector-owned check-message sends a typing action before the reply in managed Claude-session mode' );
    is( $post_calls[0][1]{action}, 'typing', 'collector-owned check-message uses Telegram typing status while Claude is generating the reply' );
    is( $post_calls[-2][0], 'sendMessage', 'collector-owned check-message sends the final Telegram reply after the typing action and verbose trace' );
    is( $post_calls[-2][1]{text}, 'Collector reply from Claude session.', 'collector-owned check-message sends the Claude-generated reply text' );
    is( $typing_events[0], 'guard-start', 'collector-owned check-message starts the typing guard before managed reply work' );
    is( $typing_events[1], 'send', 'collector-owned check-message emits the initial verbose trace while the typing guard is active' );
    is( $typing_events[2], 'resume', 'collector-owned check-message resumes Claude while the typing guard is active' );
    ok( scalar( grep { $_ eq 'send' } @typing_events ) >= 1, 'collector-owned check-message performs Telegram sends while the typing guard remains active' );
    is( $typing_events[-1], 'guard-stop', 'collector-owned check-message stops the typing guard after Telegram delivery work finishes' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my @typing_events;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 301,
                        message   => {
                            message_id => 44,
                            text       => 'These make it better',
                            chat       => { id => 66, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary, $opts ) = @_;
            push @resume_calls, [ $session_id, $prompt, $summary ];
            push @typing_events, 'resume';
            $opts->{on_progress}->('Turn started') if $opts && $opts->{on_progress};
            $opts->{on_progress}->('Agent: Planning the next step') if $opts && $opts->{on_progress};
            $opts->{on_progress}->('Running command: /bin/bash -lc pwd') if $opts && $opts->{on_progress};
            $opts->{on_progress}->('Command finished (exit 0): /bin/bash -lc pwd') if $opts && $opts->{on_progress};
            return 'Done. Final task result.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            push @typing_events, 'send' if $method eq 'sendMessage' && ( $params->{text} || q{} ) eq 'Done. Final task result.';
            return {
                ok     => JSON::XS::true,
                result => {
                    message_id => ( $method eq 'sendMessage' ? 900 : 901 ),
                    chat       => { id => $params->{chat_id} },
                    text       => $params->{text},
                },
            };
        },
        typing_guard_runner => sub {
            my ( $summary, $self ) = @_;
            push @typing_events, 'typing-start';
            return sub {
                push @typing_events, 'typing-stop';
                return 1;
            };
        },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    my @texts = map { $_->[1]{text} } grep { $_->[1]{text} } @post_calls;
    is( $result->{processed}, 1, 'collector-owned check-message processes the inbound Telegram message' );
    is( $result->{replied}, 1, 'collector-owned check-message still sends the final Telegram reply' );
    is_deeply( \@typing_events, [ 'typing-start', 'resume', 'send', 'typing-stop' ], 'collector-owned check-message keeps typing around the managed Claude work through final delivery' );
    is( scalar @resume_calls, 1, 'collector-owned check-message resumes Claude once when the first reply is substantive' );
    is( $post_calls[1][0], 'sendMessage', 'collector-owned check-message sends a verbose progress message before the final reply even for conversational follow-up text' );
    like( $post_calls[1][1]{text}, qr/Claude verbose/, 'collector-owned check-message opens the progress stream with a verbose trace message' );
    like( $post_calls[1][1]{text}, qr/Resuming active Claude session/, 'collector-owned check-message emits an immediate verbose kickoff line before richer Claude events arrive' );
    ok( scalar( grep { $_->[0] eq 'editMessageText' } @post_calls ) >= 1, 'collector-owned check-message updates the verbose trace in place' );
    like( join( "\n---\n", @texts ), qr/Agent: Planning the next step/, 'collector-owned check-message streams real agent events into Telegram' );
    like( join( "\n---\n", @texts ), qr/Running command: \/bin\/bash -lc pwd/, 'collector-owned check-message streams real command-start events into Telegram' );
    like( join( "\n---\n", @texts ), qr/Final reply sent/, 'collector-owned check-message records final delivery in the verbose trace' );
    is( $post_calls[-2][1]{text}, 'Done. Final task result.', 'collector-owned check-message still sends the final substantive Telegram reply' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my @tmux_sends;
    my $transcript_root = File::Spec->catdir( $runtime, '.claude', 'projects', '-encoded-project' );
    make_path($transcript_root);
    my $transcript_file = File::Spec->catfile( $transcript_root, 'paired-session-target.jsonl' );
    _write( $transcript_file, q{} );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-session',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 9001,
                        message   => {
                            message_id => 301,
                            text       => 'Hi from unpaired chat',
                            chat       => { id => 707, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
        tmux_send_runner => sub {
            push @tmux_sends, [@_];
            return 1;
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 901, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->set_listener_audit_enabled( 'pairing-session', 1 );
    $manager->write_listener_pairing_claim(
        $manager->listener_shared_paths_for_session('pairing-session'),
        {
            session_id => 'pairing-session',
            claimed_at => '2026-06-04 12:10:00',
        },
    );
    $manager->write_claude_target_session_id( 'pairing-session', 'paired-session-target' );
    my $result = $manager->execute_check_messages( 'pairing-session', 1, 0 );
    my $state = $manager->read_listener_pairing_state( $manager->listener_paths_for_session('pairing-session') );
    my $claim = $manager->read_listener_pairing_claim( $manager->listener_shared_paths_for_session('pairing-session') );
    my $audit = $manager->read_text_file( $manager->listener_paths_for_session('pairing-session')->{audit_file} );
    is( $result->{processed}, 1, 'pairing gate still records the unpaired inbound message' );
    is( $result->{replied}, 1, 'pairing gate sends one pairing command reply for the first unpaired message' );
    is( scalar @resume_calls, 0, 'pairing gate does not resume Claude before the session is paired' );
    is( scalar @tmux_sends, 0, 'pairing gate does not inject the unpaired trigger message into a live tmux-backed Claude session' );
    is( $post_calls[0][0], 'sendMessage', 'pairing gate sends the pairing command through a normal Telegram reply' );
    like( $post_calls[0][1]{text}, qr/\Ad2 telegram-claude\.pair [0-9a-f]{16}\z/, 'pairing gate replies with the local pairing command and a random hex code' );
    is( $state->{pending_chat_id}, 707, 'pairing gate records the pending chat id for the first unpaired user' );
    is( $state->{pairing_code}, ( split / /, $post_calls[0][1]{text} )[-1], 'pairing gate persists the same challenge code it returned to Telegram' );
    like( $audit, qr/"type"\s*:\s*"pairing\.challenge\.sent"/, 'pairing gate records the challenge send decision in the session audit' );
    is( $manager->read_text_file($transcript_file), q{}, 'pairing gate does not append the unpaired trigger message into the shared Claude transcript' );
    is_deeply( $claim, {}, 'pairing gate clears the shared pairing claim after the replacement challenge is issued' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $runtime_dir = File::Spec->catdir( $runtime, 'skills' );
    make_path($runtime_dir);
    my @post_calls;
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'skills',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 12,
                        message   => {
                            message_id => 8,
                            text       => '/status@jamesthexe_bot',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 500, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
        process_list_runner => sub { return [] },
        tmux_panes_runner   => sub { return [] },
    );
    _write( File::Spec->catfile( $runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 88 } ) );
    _write( File::Spec->catfile( $runtime_dir, 'claude.session' ), "session-status-77\n" );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{processed}, 1, 'execute_check_messages processes a paired Telegram /status slash command' );
    is( $result->{replied}, 1, 'execute_check_messages replies to a paired Telegram /status slash command' );
    is( scalar @resume_calls, 0, 'execute_check_messages does not resume Claude for a handled Telegram slash command' );
    is( $post_calls[0][0], 'sendMessage', 'execute_check_messages sends a plain Telegram reply for /status' );
    like( $post_calls[0][1]{text}, qr/\AClaude \/status unavailable\.\n/, 'execute_check_messages now returns an explicit unavailable message when no live Claude pane exists for /status' );
    like( $post_calls[0][1]{text}, qr/session-status-77/, 'execute_check_messages names the mapped Claude session in the unavailable /status reply' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $runtime_dir = File::Spec->catdir( $runtime, 'skills' );
    make_path($runtime_dir);
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'skills',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 13,
                        message   => {
                            message_id => 9,
                            text       => '/status',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            die "Telegram POST failed for sendMessage: 500 slash command rejected\n"
              if $method eq 'sendMessage';
            return { ok => JSON::XS::true, result => { message_id => 501, chat => { id => $params->{chat_id} } } };
        },
    );
    _write( File::Spec->catfile( $runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 88 } ) );
    _write( File::Spec->catfile( $runtime_dir, 'claude.session' ), "session-status-88\n" );
    my $paths = $manager->listener_paths_for_session('skills');
    $manager->set_listener_audit_enabled( 'skills', 1 );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    my $audit = $manager->read_text_file( $paths->{audit_file} );
    is( $result->{processed}, 1, 'execute_check_messages still processes a slash command when the Telegram reply send fails' );
    is( $result->{replied}, 0, 'execute_check_messages does not count a failed slash-command reply as sent' );
    is( scalar @{ $result->{reply_errors} }, 1, 'execute_check_messages records one reply error for the failed Telegram slash-command send' );
    like( $result->{reply_errors}[0]{error}, qr/slash command rejected/, 'execute_check_messages exposes the Telegram slash-command reply failure detail' );
    like( $audit, qr/"type"\s*:\s*"slash_command\.reply_failed"/, 'execute_check_messages audits a failed Telegram slash-command reply send' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-session',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 9002,
                        message   => {
                            message_id => 302,
                            text       => 'Still talking before pairing',
                            chat       => { id => 707, type => 'private' },
                        },
                    },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 902, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_listener_pairing_state(
        $manager->listener_paths_for_session('pairing-session'),
        {
            pending_chat_id => 707,
            pairing_code    => 'deadbeefcafebabe',
        },
    );
    my $result = $manager->execute_check_messages( 'pairing-session', 1, 0 );
    is( $result->{processed}, 1, 'pairing gate still records repeated unpaired messages' );
    is( $result->{replied}, 0, 'pairing gate ignores repeated messages from the pending unpaired chat until the local pair command runs' );
    is( scalar @post_calls, 0, 'pairing gate sends no second challenge reply before pairing is completed locally' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-session',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 90021,
                        message   => {
                            message_id => 3021,
                            text       => 'Second unpaired chat should be ignored',
                            chat       => { id => 808, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 9021, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_listener_pairing_state(
        $manager->listener_paths_for_session('pairing-session'),
        {
            pending_chat_id => 707,
            pairing_code    => 'deadbeefcafebabe',
        },
    );
    my $result = $manager->execute_check_messages( 'pairing-session', 1, 0 );
    is( $result->{processed}, 1, 'pairing gate still records outsider messages while another chat has the pending challenge' );
    is( $result->{replied}, 0, 'pairing gate ignores a different unpaired chat while the pending challenge belongs to someone else' );
    is( scalar @resume_calls, 0, 'pairing gate does not resume Claude for a different unpaired chat while pairing is pending elsewhere' );
    is( scalar @post_calls, 0, 'pairing gate does not send a second challenge to a different unpaired chat while one is already pending' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-session',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 90022,
                        message   => {
                            message_id => 3022,
                            text       => 'First pairing challenge send should fail cleanly',
                            chat       => { id => 909, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for sendMessage: 500 Pairing challenge send failure\n" if $method eq 'sendMessage';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 9022, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $result = $manager->execute_check_messages( 'pairing-session', 1, 0 );
    my $state = $manager->read_listener_pairing_state( $manager->listener_paths_for_session('pairing-session') );
    is( $result->{processed}, 1, 'pairing gate still records the first unpaired message when the challenge reply send fails' );
    is( $result->{replied}, 0, 'pairing gate does not count a failed challenge reply as replied' );
    is( scalar @resume_calls, 0, 'pairing gate still does not resume Claude when the challenge reply send fails' );
    like( $result->{reply_errors}[0]{error}, qr/Pairing challenge send failure/, 'pairing gate records the challenge reply send failure' );
    is( $state->{pending_chat_id}, 909, 'pairing gate still persists the pending chat after a failed challenge reply send' );
    is( scalar @post_calls, 1, 'pairing gate attempts the challenge reply once when the send fails' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $runtime, 'pairing-session' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
        },
    );
    my $paths = $manager->listener_paths_for_session('pairing-session');
    $manager->write_listener_pairing_state(
        $paths,
        {
            pending_chat_id => 707,
            pairing_code    => 'deadbeefcafebabe',
        },
    );
    my $result = $manager->execute_pair('deadbeefcafebabe');
    my $state = $manager->read_listener_pairing_state($paths);
    is( $result->{paired_chat_id}, 707, 'execute_pair pairs the pending Telegram chat to the current session' );
    is( $state->{paired_chat_id}, 707, 'execute_pair persists the paired chat id' );
    ok( !exists $state->{pairing_code}, 'execute_pair clears the consumed challenge code' );
    ok( !exists $state->{pending_chat_id}, 'execute_pair clears the pending chat after successful pairing' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $runtime, 'pairing-session' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => $workspace,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
        },
    );
    my $paths = $manager->listener_paths_for_session('pairing-session');
    my $other_paths = $manager->listener_paths_for_session('other-session');
    $manager->write_listener_pairing_state(
        $paths,
        {
            pending_chat_id    => 707,
            pairing_code       => 'deadbeefcafebabe',
            challenge_sent_at  => '2026-06-04 11:00:00',
            paired_chat_id     => 808,
            paired_at          => '2026-06-04 10:59:00',
        },
    );
    $manager->write_listener_pairing_state(
        $other_paths,
        {
            paired_chat_id => 909,
            paired_at      => '2026-06-04 10:58:00',
        },
    );
    my $result = $manager->execute_pair('--clear-unknown-devices');
    my $state = $manager->read_listener_pairing_state($paths);
    my $other_state = $manager->read_listener_pairing_state($other_paths);
    my $claim = $manager->read_listener_pairing_claim( $manager->listener_shared_paths_for_session('pairing-session') );
    is( $result->{action}, 'clear-unknown-devices', 'execute_pair reports the clear-unknown-devices action' );
    ok( $result->{cleared_pending}, 'execute_pair clears the current session pending Telegram challenge' );
    ok( $result->{cleared_paired}, 'execute_pair clears the current session paired Telegram chat' );
    is_deeply( $state, {}, 'execute_pair clears all pairing state for the current workspace session' );
    is( $other_state->{paired_chat_id}, 909, 'execute_pair leaves other workspace pairing ownership untouched' );
    is( $claim->{session_id}, 'pairing-session', 'execute_pair records a shared pairing claim for the current workspace session' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $home, 'pairing-session' );
    make_path($workspace);
    my $legacy_runtime_root = File::Spec->catdir( $home, '.telegram-claude' );
    my $legacy_runtime_dir = File::Spec->catdir( $legacy_runtime_root, 'pairing-session' );
    make_path($legacy_runtime_dir);
    _write(
        File::Spec->catfile( $legacy_runtime_dir, 'pairing.json' ),
        encode_json(
            {
                pending_chat_id   => 707,
                pairing_code      => 'deadbeefcafebabe',
                challenge_sent_at => '2026-06-04 11:00:00',
                paired_chat_id    => 808,
                paired_at         => '2026-06-04 10:59:00',
            }
        ),
    );
    my $manager = new_manager(
        cwd  => $workspace,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-alpha',
        },
    );
    my $result = $manager->execute_pair('--clear-unknown-devices');
    my $paths = $manager->listener_paths_for_session('pairing-session');
    my $state = $manager->read_listener_pairing_state($paths);
    ok( $result->{cleared_pending}, 'execute_pair --clear-unknown-devices clears a pending challenge migrated from the legacy flat runtime' );
    ok( $result->{cleared_paired}, 'execute_pair --clear-unknown-devices clears a paired chat migrated from the legacy flat runtime' );
    is_deeply( $state, {}, 'execute_pair --clear-unknown-devices persists the cleared state in the token-scoped runtime after migrating the legacy files' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $workspace = File::Spec->catdir( $runtime, 'websites' );
    make_path($workspace);
    my $manager = new_manager(
        cwd  => File::Spec->catdir( $runtime, 'skills' ),
        home => $runtime,
        env  => {
            PWD                           => $workspace,
            WORKSPACE_REF                 => 'skills',
            TICKET_REF                    => 'skills',
            CLAUDE_SESSION_ID              => 'skills',
            TELEGRAM_CLAUDE_SESSION_ID     => 'skills',
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN            => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR    => $runtime,
        },
    );
    my $paths = $manager->listener_paths_for_session('websites');
    $manager->write_listener_pairing_state(
        $paths,
        {
            pending_chat_id    => 707,
            pairing_code       => 'deadbeefcafebabe',
            challenge_sent_at  => '2026-06-04 11:00:00',
            paired_chat_id     => 808,
            paired_at          => '2026-06-04 10:59:00',
        },
    );
    my $result = $manager->execute_pair('--clear-unknown-devices');
    is( $result->{session_id}, 'websites', 'execute_pair --clear-unknown-devices follows the active shell workspace instead of leaked session env' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @resume_calls;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-session',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 9003,
                        message   => {
                            message_id => 303,
                            text       => 'Now do the work',
                            chat       => { id => 707, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'Paired reply.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 903, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_listener_pairing_state(
        $manager->listener_paths_for_session('pairing-session'),
        {
            paired_chat_id => 707,
            paired_at      => '2026-05-22 12:00:00',
        },
    );
    $manager->write_claude_target_session_id( 'pairing-session', 'paired-session-target' );
    my $result = $manager->execute_check_messages( 'pairing-session', 1, 0 );
    is( $result->{replied}, 1, 'paired chat resumes normal reply behavior after local pairing' );
    is( scalar @resume_calls, 1, 'paired chat is allowed through to the Claude session' );
    is( $post_calls[-2][1]{text}, 'Paired reply.', 'paired chat still receives the final Claude reply text' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-unpaired-live-block';
    my $runtime_dir = File::Spec->catdir( $home, 'skills' );
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($runtime_dir);
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write( $session_file, q{} );
    my @resume_calls;
    my @tmux_calls;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_CLAUDE_SESSION_ID        => 'skills',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => $session_id,
            TELEGRAM_CLAUDE_AUDIT             => '1',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 77,
                    tty    => 'pts/0',
                    etimes => 4,
                    cmd    => "claude --resume $session_id",
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%77',
                    tty             => '/dev/pts/0',
                    current_command => 'node',
                },
            ];
        },
        tmux_send_runner => sub {
            push @tmux_calls, [@_];
            return 1;
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
    );
    my $reply = $manager->claude_session_reply_for_update(
        {
            text       => 'Give me the pairing code',
            chat       => { id => 909, type => 'private' },
            message_id => 4001,
        },
    );
    ok( !defined $reply, 'claude_session_reply_for_update refuses to enter the Claude session path for an unpaired chat' );
    is( scalar @tmux_calls, 0, 'claude_session_reply_for_update does not inject an unpaired chat into the live tmux pane' );
    is( scalar @resume_calls, 0, 'claude_session_reply_for_update does not fall back to detached resume for an unpaired chat' );
    my $audit = $manager->read_text_file( $manager->listener_paths->{audit_file} );
    like( $audit, qr/"type":"pairing\.reply_path_blocked"/, 'claude_session_reply_for_update audits the blocked unpaired Claude-session path' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @resume_calls;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-session',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 9004,
                        message   => {
                            message_id => 304,
                            text       => 'Different chat should be ignored',
                            chat       => { id => 808, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 904, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_listener_pairing_state(
        $manager->listener_paths_for_session('pairing-session'),
        {
            paired_chat_id => 707,
            paired_at      => '2026-05-22 12:00:00',
        },
    );
    my $result = $manager->execute_check_messages( 'pairing-session', 1, 0 );
    is( $result->{processed}, 1, 'paired-session security still records the ignored outsider message' );
    is( $result->{replied}, 0, 'paired-session security ignores messages from unpaired chats after pairing is complete' );
    is( scalar @resume_calls, 0, 'paired-session security does not resume Claude for outsider chats' );
    is( scalar @post_calls, 0, 'paired-session security does not reply to outsider chats' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 1,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-disabled-session',
        },
    );
    my $paths = $manager->listener_paths_for_session('pairing-disabled-session');
    $manager->set_listener_audit_enabled( 'pairing-disabled-session', 1 );
    my $result = $manager->listener_pairing_action(
        {
            chat       => { id => 919 },
            update_id  => 99001,
            message_id => 9901,
            text       => 'pairing bypassed',
        },
        $paths,
    );
    my $audit = $manager->read_text_file( $paths->{audit_file} );
    is( $result->{allow}, 1, 'listener_pairing_action allows the chat when pairing is explicitly disabled' );
    like( $audit, qr/"type"\s*:\s*"pairing\.allowed"/, 'listener_pairing_action records pairing.allowed in the audit when pairing is explicitly disabled' );
    like( $audit, qr/"reason"\s*:\s*"disabled"/, 'listener_pairing_action records the disabled reason in the audit when pairing is bypassed' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_DISABLE_PAIRING => 0,
            TELEGRAM_BOT_TOKEN             => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR     => $runtime,
            CLAUDE_SESSION_ID               => 'pairing-missing-chat-session',
        },
    );
    my $paths = $manager->listener_paths_for_session('pairing-missing-chat-session');
    $manager->set_listener_audit_enabled( 'pairing-missing-chat-session', 1 );
    my $result = $manager->listener_pairing_action(
        {
            chat       => {},
            update_id  => 99002,
            message_id => 9902,
            text       => 'no chat id',
        },
        $paths,
    );
    my $audit = $manager->read_text_file( $paths->{audit_file} );
    is( $result->{allow}, 1, 'listener_pairing_action allows updates with no chat id' );
    like( $audit, qr/"type"\s*:\s*"pairing\.allowed"/, 'listener_pairing_action records pairing.allowed in the audit when chat id is missing' );
    like( $audit, qr/"reason"\s*:\s*"missing-chat-id"/, 'listener_pairing_action records the missing-chat-id reason in the audit' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 10101,
                        message   => {
                            message_id => 193,
                            text       => 'Static collector reply',
                            chat       => { id => 98, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @resume_calls, [@_];
            return 'unexpected';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 782, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $result = $manager->execute_check_messages( 'skills', 1, 0, 'Static collector reply sent.' );
    is( $result->{processed}, 1, 'collector-owned check-message processes inbound messages in static reply mode too' );
    is( $result->{replied}, 1, 'collector-owned check-message sends a static reply when explicit reply text is supplied' );
    is( scalar @resume_calls, 0, 'collector-owned check-message does not resume Claude in static reply mode' );
    is( scalar @post_calls, 1, 'collector-owned check-message sends only the final Telegram reply in static reply mode' );
    is( $post_calls[0][0], 'sendMessage', 'collector-owned check-message does not send typing status in static reply mode' );
    is( $post_calls[0][1]{text}, 'Static collector reply sent.', 'collector-owned check-message sends the explicit static reply text' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @typing_events;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        typing_guard_runner => sub {
            my ( $summary, $self ) = @_;
            push @typing_events, 'guard-start';
            return sub {
                push @typing_events, 'guard-stop';
                return 1;
            };
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 1011,
                        message   => {
                            message_id => 191,
                            text       => 'Guard cleanup on failure',
                            chat       => { id => 99, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @typing_events, 'resume';
            die "Claude resume failed for Telegram reply\n";
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 780, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{processed}, 1, 'collector-owned check-message still records the inbound message when managed Claude reply generation fails' );
    is( $result->{replied}, 0, 'collector-owned check-message does not count a failed managed Claude reply generation as replied' );
    like( $result->{reply_errors}[0]{error}, qr/Claude resume failed for Telegram reply/, 'collector-owned check-message records the managed Claude failure' );
    is_deeply( \@typing_events, [ 'guard-start', 'resume', 'guard-stop' ], 'typing guard cleanup still runs when the managed Claude reply generation fails' );
    is( scalar @post_calls, 2, 'collector-owned check-message sends typing plus the initial verbose trace before the managed reply failure' );
    is( $post_calls[0][0], 'sendChatAction', 'collector-owned check-message sends typing before the managed reply failure' );
    like( $post_calls[1][1]{text}, qr/Claude verbose/, 'collector-owned check-message sends the initial verbose trace before the managed reply failure' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @typing_events;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        typing_guard_runner => sub {
            my ( $summary, $self ) = @_;
            push @typing_events, 'guard-start';
            return sub {
                push @typing_events, 'guard-stop';
                return 1;
            };
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 1012,
                        message   => {
                            message_id => 192,
                            text       => 'Guard cleanup on send failure',
                            chat       => { id => 99, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            push @typing_events, 'resume';
            return 'Reply before send failure.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @typing_events, 'send' if $method eq 'sendMessage';
            die "Telegram POST failed for sendMessage: 500 Internal Server Error\n" if $method eq 'sendMessage';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 781, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{processed}, 1, 'collector-owned check-message still records the inbound message when final Telegram delivery fails' );
    is( $result->{replied}, 0, 'collector-owned check-message does not count a failed final Telegram delivery as replied' );
    like( $result->{reply_errors}[0]{error}, qr/sendMessage: 500 Internal Server Error/, 'collector-owned check-message records the final Telegram delivery failure' );
    is_deeply( \@typing_events, [ 'guard-start', 'send', 'resume', 'send', 'guard-stop' ], 'typing guard cleanup still runs after a final Telegram delivery failure even with the initial verbose trace send' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { ok => JSON::XS::true },
            };
        },
    );
    my @typing_errors;
    my $returned = $manager->with_listener_typing_status(
        {
            update_id => 2001,
            message_id => 91,
            chat => { id => 99, type => 'private' },
            text => 'void context branch',
        },
        typing_errors => \@typing_errors,
        code => sub {
            push @typing_errors, { marker => 'callback-ran' };
            return 'unused';
        },
    );
    is( $returned, 'unused', 'with_listener_typing_status returns callback result in scalar context' );
    is( $post_calls[0][0], 'sendChatAction', 'with_listener_typing_status sends the initial typing action directly' );
    is( $typing_errors[-1]{marker}, 'callback-ran', 'with_listener_typing_status runs the callback body' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            die "Telegram POST failed for sendChatAction: 429 Too Many Requests\n" if $method eq 'sendChatAction';
            return { ok => JSON::XS::true, result => { ok => JSON::XS::true } };
        },
    );
    my $error = $manager->send_telegram_typing_action_for_chat(88);
    is( $error->{chat_id}, 88, 'send_telegram_typing_action_for_chat returns the chat id when Telegram typing fails directly' );
    like( $error->{error}, qr/sendChatAction: 429 Too Many Requests/, 'send_telegram_typing_action_for_chat returns the Telegram typing failure detail instead of dying' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { ok => JSON::XS::true },
            };
        },
    );
    my @values = $manager->with_listener_typing_status(
        {
            update_id => 20011,
            message_id => 911,
            chat => { id => 99, type => 'private' },
            text => 'list context branch',
        },
        code => sub {
            return ( 'first', 'second' );
        },
    );
    is_deeply( \@values, [ 'first', 'second' ], 'with_listener_typing_status returns callback results in list context' );
    is( $post_calls[0][0], 'sendChatAction', 'with_listener_typing_status still sends typing in list context' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { ok => JSON::XS::true },
            };
        },
    );
    my $ran = 0;
    $manager->with_listener_typing_status(
        {
            update_id => 20012,
            message_id => 912,
            chat => { id => 99, type => 'private' },
            text => 'void context branch',
        },
        code => sub {
            $ran = 1;
            return 'ignored';
        },
    );
    ok( $ran, 'with_listener_typing_status runs the callback body in void context' );
    is( $post_calls[0][0], 'sendChatAction', 'with_listener_typing_status still sends typing in void context' );
}

{
    my $manager = new_manager;
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'system', subtype => 'init' } ) ],
        ['Session resumed'],
        'claude_progress_lines_for_event formats the stream-json system init event'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'system', subtype => 'api_retry' } ) ],
        [],
        'claude_progress_lines_for_event ignores non-init system events'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'result', subtype => 'success', result => 'done' } ) ],
        ['Turn completed'],
        'claude_progress_lines_for_event formats the final result event'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'assistant', message => { role => 'assistant', content => [ { type => 'tool_use', name => 'Bash', input => { command => '/bin/bash -lc pwd' } } ] } } ) ],
        ['Running tool: Bash: /bin/bash -lc pwd'],
        'claude_progress_lines_for_event formats assistant tool_use events'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'user', message => { role => 'user', content => [ { type => 'tool_result', content => "/tmp\n" } ] } } ) ],
        ['Output: /tmp'],
        'claude_progress_lines_for_event formats string-form user tool_result output'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'user', message => { role => 'user', content => [ { type => 'tool_result', content => [ { type => 'text', text => "first line\nsecond line" }, { type => 'image' } ] } ] } } ) ],
        [ 'Output: first line', 'Output: second line' ],
        'claude_progress_lines_for_event formats array-form user tool_result output and ignores non-text chunks'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'assistant', message => { role => 'assistant', content => [ { type => 'text', text => "Planning\nDone" } ] } } ) ],
        [ 'Agent: Planning', 'Agent: Done' ],
        'claude_progress_lines_for_event formats assistant text messages line by line'
    );
    is_deeply(
        [ $manager->claude_progress_lines_for_event( { type => 'assistant', message => { role => 'assistant', content => [ { type => 'thinking', thinking => 'hmm' } ] } } ) ],
        [],
        'claude_progress_lines_for_event returns no lines for unrelated content blocks'
    );
}

{
    my $manager = new_manager;
    ok(
        $manager->listener_should_stream_progress( { text => 'These make it better', chat => { id => 1 }, message_id => 2 } ),
        'listener_should_stream_progress stays on for conversational managed Claude replies'
    );
    ok(
        $manager->telegram_message_requires_completion( { text => 'Run all the tests and check if any test not good enough' } ),
        'telegram_message_requires_completion recognizes run-and-check task requests as long-running work'
    );
    ok(
        $manager->telegram_message_requires_completion( { text => 'Review the current implementation and verify the release gate' } ),
        'telegram_message_requires_completion recognizes review-and-verify task requests as long-running work'
    );
    ok(
        !$manager->telegram_message_requires_completion( { text => 'What is the status?' } ),
        'telegram_message_requires_completion does not force verbose task streaming for simple status questions'
    );
}

{
    my $manager = new_manager;
    my @trimmed = $manager->listener_verbose_trimmed_lines( ('short line') x 11, ( 'x' x 3400 ) );
    ok( scalar(@trimmed) < 12, 'listener_verbose_trimmed_lines drops older lines until the rendered verbose message fits Telegram limits' );
    is( $trimmed[-1], 'x' x 3400, 'listener_verbose_trimmed_lines keeps the newest line while trimming oversized verbose output' );
    ok( length( $manager->listener_verbose_text(@trimmed) ) <= 3500, 'listener_verbose_trimmed_lines returns text that fits the Telegram edit budget' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-task-work',
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 995, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $reporter = $manager->start_listener_verbose_reporter(
        {
            update_id  => 30020,
            message_id => 320,
            chat       => { id => 88, type => 'private' },
            text       => 'Finish all tasks with all gates',
        },
    );
    ok( $reporter, 'start_listener_verbose_reporter returns a reporter object for managed Claude-session updates' );
    ok( $reporter->{emit}->('Turn started'), 'start_listener_verbose_reporter can emit the first verbose line' );
    ok( $reporter->{emit}->('Running command: /bin/bash -lc pwd'), 'start_listener_verbose_reporter can append later verbose lines' );
    ok( $reporter->{finish}->(), 'start_listener_verbose_reporter exposes a finish callback' );
    is( $post_calls[0][0], 'sendMessage', 'start_listener_verbose_reporter sends the first verbose trace message' );
    like( $post_calls[0][1]{text}, qr/Claude verbose\n- Turn started/, 'start_listener_verbose_reporter renders the initial verbose trace text' );
    is( $post_calls[1][0], 'editMessageText', 'start_listener_verbose_reporter edits the same Telegram message for later lines' );
    like( $post_calls[1][1]{text}, qr/Running command: \/bin\/bash -lc pwd/, 'start_listener_verbose_reporter includes later streamed steps in the edited message' );
}

{
    # DD-384: a streamed line that renders the same accumulated verbose text must
    # NOT trigger an editMessageText with unchanged text (Telegram returns
    # 400 "message is not modified"); the reporter skips the no-op edit and stays
    # enabled so later distinct lines still update in place.
    my @post_calls;
    my $manager = new_manager(
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for editMessageText: 400 Bad Request\n"
              if $method eq 'editMessageText'
              && @post_calls > 1
              && $params->{text} eq $post_calls[0][1]{text};
            return {
                ok     => JSON::XS::true,
                result => { message_id => 661, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my @errors;
    my $reporter = $manager->start_listener_verbose_reporter(
        {
            update_id  => 30021,
            message_id => 321,
            chat       => { id => 88, type => 'private' },
            text       => 'Finish all tasks with all gates',
        },
        on_error => sub { push @errors, $_[0]; return 1; },
    );
    ok( $reporter->{emit}->('Session resumed'), 'reporter sends the first verbose line' );
    ok( $reporter->{emit}->('Session resumed'), 'reporter skips the no-op edit when the accumulated text is unchanged' );
    ok( $reporter->{emit}->('Agent: Today is June 11, 2026.'), 'reporter still edits in place for a later distinct line' );
    is( scalar(@errors), 0, 'reporter records no error because the unchanged-text edit was skipped, not attempted' );
    is( scalar( grep { $_->[0] eq 'editMessageText' } @post_calls ), 1, 'reporter issues exactly one editMessageText (only for the changed text), not for the duplicate' );
    is( $post_calls[0][0], 'sendMessage', 'reporter sent the initial trace message' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @errors;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-task-work',
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for editMessageText: 500 Internal Server Error\n" if $method eq 'editMessageText';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 996, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $reporter = $manager->start_listener_verbose_reporter(
        {
            update_id  => 30021,
            message_id => 321,
            chat       => { id => 88, type => 'private' },
            text       => 'Finish all tasks with all gates',
        },
        on_error => sub { push @errors, @_; return 1; },
    );
    ok( $reporter->{emit}->('Turn started'), 'start_listener_verbose_reporter still emits the first line when Telegram accepts the initial trace message' );
    ok( !$reporter->{emit}->('Running command: /bin/bash -lc pwd'), 'start_listener_verbose_reporter converts later edit failures into a false return instead of dying' );
    like( $errors[0], qr/editMessageText: 500 Internal Server Error/, 'start_listener_verbose_reporter reports the Telegram verbose edit failure through the error callback' );
    is( $post_calls[0][0], 'sendMessage', 'start_listener_verbose_reporter still posts the initial verbose trace message before the edit failure' );
    is( $post_calls[1][0], 'editMessageText', 'start_listener_verbose_reporter attempted the later in-place edit before reporting the failure' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @errors;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN               => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR       => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE     => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-task-work',
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for sendMessage: 500 Initial verbose trace rejected\n" if $method eq 'sendMessage';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 997, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $reporter = $manager->start_listener_verbose_reporter(
        {
            update_id  => 30022,
            message_id => 322,
            chat       => { id => 88, type => 'private' },
            text       => 'Finish all tasks with all gates',
        },
        on_error => sub { push @errors, @_; return 1; },
    );
    ok( $reporter, 'start_listener_verbose_reporter still returns a reporter object when the first verbose send fails' );
    ok( !$reporter->{emit}->('Turn started'), 'start_listener_verbose_reporter returns false instead of dying when the first verbose send is rejected' );
    like( $errors[0], qr/sendMessage: 500 Initial verbose trace rejected/, 'start_listener_verbose_reporter reports the initial verbose send failure through the error callback' );
    is( $post_calls[0][0], 'sendMessage', 'start_listener_verbose_reporter attempted the initial verbose trace send before disabling itself' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $paths = $manager->listener_paths_for_session('audit-direct');
    ok( !$manager->listener_audit_enabled($paths), 'listener audit is disabled by default without env or marker file' );
    ok( $manager->set_listener_audit_enabled( 'audit-direct', 1 ), 'set_listener_audit_enabled writes the per-session audit marker file' );
    ok( $manager->listener_audit_enabled($paths), 'listener audit becomes enabled after the marker file is written' );
    ok(
        $manager->append_listener_audit_event(
            $paths,
            'audit.direct',
            {
                worked => JSON::XS::true,
                note   => 'written from direct test',
            },
        ),
        'append_listener_audit_event writes a JSONL audit row when audit is enabled',
    );
    my @rows = grep { defined $_ && $_ ne q{} } split /\n/, $manager->read_text_file( $paths->{audit_file} );
    my $decoded = decode_json( $rows[0] );
    is( $decoded->{type}, 'audit.direct', 'append_listener_audit_event persists the event type' );
    is( $decoded->{note}, 'written from direct test', 'append_listener_audit_event persists the supplied payload fields' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'reply-failed-session',
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            die "Telegram POST failed for sendMessage: 500 generic reply failure\n" if $method eq 'sendMessage';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 777, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $paths = $manager->listener_paths;
    ok( $manager->set_listener_audit_enabled( 'reply-failed-session', 1 ), 'reply.failed path enables the per-session audit log before processing the update' );
    my @typing_errors;
    my @progress_errors;
    my @reply_errors;
    my $result = $manager->process_listener_update(
        session_id      => 'reply-failed-session',
        paths           => $paths,
        summary         => {
            update_id  => 70,
            message_id => 71,
            text       => 'This generic listener reply should fail on send',
            chat       => { id => 72, type => 'private' },
        },
        reply_text      => 'Static reply that will fail during send',
        typing_errors   => \@typing_errors,
        progress_errors => \@progress_errors,
        reply_errors    => \@reply_errors,
    );
    is( $result->{replied}, 0, 'process_listener_update does not count a failed generic listener reply as replied' );
    is( scalar @reply_errors, 1, 'process_listener_update records the failed generic listener reply' );
    like( $reply_errors[0]{error}, qr/500 generic reply failure/, 'process_listener_update preserves the generic reply failure detail' );
    is_deeply( \@typing_errors, [], 'process_listener_update generic send failure does not invent typing errors' );
    is_deeply( \@progress_errors, [], 'process_listener_update generic send failure does not invent progress errors' );
    my @rows = grep { defined $_ && $_ ne q{} } split /\n/, $manager->read_text_file( $paths->{audit_file} );
    my $decoded = decode_json( $rows[-1] );
    is( $decoded->{type}, 'reply.failed', 'process_listener_update writes the reply.failed audit event for generic listener send failures' );
    like( $decoded->{error}, qr/500 generic reply failure/, 'process_listener_update writes the generic reply failure detail into the audit row' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-task-work',
        },
        fork_runner => sub { return undef; },
        post_runner => sub {
            my ( $method, $params ) = @_;
            return {
                ok     => JSON::XS::true,
                result => { message_id => 990, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $guard = $manager->start_listener_progress_guard(
        {
            update_id  => 30001,
            message_id => 301,
            chat       => { id => 88, type => 'private' },
            text       => 'Finish all tasks with all gates',
        },
    );
    ok( $guard, 'start_listener_progress_guard falls back to a cleanup callback when the progress fork cannot be created' );
    ok( $guard->(), 'progress cleanup callback from fork failure is still callable' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $progress_log = File::Spec->catfile( $runtime, 'progress.log' );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-task-work',
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            open my $fh, '>>', $progress_log or die $!;
            print {$fh} "$method\n";
            close $fh or die $!;
            return {
                ok     => JSON::XS::true,
                result => { message_id => 991, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    my $summary = {
        update_id  => 30002,
        message_id => 302,
        chat       => { id => 88, type => 'private' },
        text       => 'Finish all tasks with all gates',
    };
    is(
        $manager->listener_progress_text( 'start', 0 ),
        'Claude is working on your request in this session. I will send the final result when the work is done.',
        'listener_progress_text returns the initial managed progress message'
    );
    is(
        $manager->listener_progress_text( 'continue', 1 ),
        'Claude is still working on your request...',
        'listener_progress_text returns the repeating managed progress message'
    );
    is( $manager->listener_progress_interval_seconds, 5, 'listener_progress_interval_seconds returns the default progress heartbeat interval' );
    local *Telegram::Claude::Manager::listener_progress_interval_seconds = sub { return 0.1; };
    my $guard = $manager->start_listener_progress_guard($summary);
    ok( $guard, 'start_listener_progress_guard returns a cleanup callback for the real forked progress path' );
    select undef, undef, undef, 0.25;
    $guard->();
    my $log = do {
        open my $fh, '<', $progress_log or die $!;
        local $/;
        <$fh>;
    };
    like( $log, qr/sendMessage/, 'start_listener_progress_guard posts the initial progress message' );
    like( $log, qr/editMessageText/, 'start_listener_progress_guard refreshes the progress message while work is still running' );
    like( $log, qr/deleteMessage/, 'start_listener_progress_guard deletes the progress message after cleanup' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
    );
    my $guard = $manager->start_listener_typing_guard(
        {
            update_id => 2002,
            message_id => 92,
            chat => { type => 'private' },
            text => q{},
        },
    );
    ok( !defined $guard, 'start_listener_typing_guard returns undef when the update does not qualify for managed typing status' );
    ok( !defined $manager->send_listener_typing_action( { chat => { id => 99 }, text => q{} } ), 'send_listener_typing_action is a no-op when the update does not qualify for typing status' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        fork_runner => sub { return undef; },
    );
    my $guard = $manager->start_listener_typing_guard(
        {
            update_id => 20021,
            message_id => 921,
            chat => { id => 99, type => 'private' },
            text => 'simulated fork failure',
        },
    );
    ok( !defined $guard, 'start_listener_typing_guard falls back cleanly when the heartbeat fork cannot be created' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $typing_log = File::Spec->catfile( $runtime, 'typing.log' );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            open my $fh, '>>', $typing_log or die $!;
            print {$fh} "$method\n";
            close $fh or die $!;
            return {
                ok     => JSON::XS::true,
                result => { ok => JSON::XS::true },
            };
        },
    );
    my $summary = {
        update_id => 2003,
        message_id => 93,
        chat => { id => 99, type => 'private' },
        text => 'forked typing guard branch',
    };
    local *Telegram::Claude::Manager::listener_typing_interval_seconds = sub { return 0.1; };
    my $guard = $manager->start_listener_typing_guard($summary);
    ok( $guard, 'start_listener_typing_guard returns a cleanup callback for the real forked heartbeat path' );
    select undef, undef, undef, 0.25;
    $guard->();
    my $log = do {
        open my $fh, '<', $typing_log or die $!;
        local $/;
        <$fh>;
    };
    like( $log, qr/sendChatAction/, 'start_listener_typing_guard sends repeated typing actions from the forked heartbeat path' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 102,
                        message   => {
                            message_id => 20,
                            text       => 'Typing failure should not block reply',
                            chat       => { id => 99, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary ) = @_;
            push @resume_calls, [ $session_id, $prompt, $summary ];
            return 'Reply still sent after typing failure.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for sendChatAction: 429 Too Many Requests\n" if $method eq 'sendChatAction';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 778, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{processed}, 1, 'collector-owned check-message still processes the inbound message when typing status fails' );
    is( $result->{replied}, 1, 'collector-owned check-message still sends the final reply when typing status fails' );
    is( scalar @resume_calls, 1, 'collector-owned check-message still resumes Claude when typing status fails' );
    is( $post_calls[0][0], 'sendChatAction', 'collector-owned check-message attempted the typing action before the reply' );
    is( $post_calls[1][0], 'sendMessage', 'collector-owned check-message still sends the reply after a typing-action failure' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 104,
                        message   => {
                            message_id => 22,
                            text       => 'Finish all tasks with all gates',
                            chat       => { id => 99, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary, $args ) = @_;
            $args->{on_progress}->('Turn started');
            $args->{on_progress}->('Running command: /bin/bash -lc pwd');
            return 'Reply still sent after progress-stream failure.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for editMessageText: 500 Internal Server Error\n" if $method eq 'editMessageText';
            return {
                ok     => JSON::XS::true,
                result => { message_id => 780 + scalar @post_calls, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
        typing_guard_runner => sub { return sub { return 1 } },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{processed}, 1, 'collector-owned check-message still records the inbound message when Telegram verbose progress edits fail mid-run' );
    is( $result->{replied}, 1, 'collector-owned check-message still sends the final reply when Telegram verbose progress edits fail mid-run' );
    is( scalar @{ $result->{progress_errors} }, 1, 'collector-owned check-message records the non-fatal Telegram verbose progress failure separately from reply errors' );
    like( $result->{progress_errors}[0]{error}, qr/editMessageText: 500 Internal Server Error/, 'collector-owned check-message preserves the Telegram verbose progress failure detail' );
    is( scalar @{ $result->{reply_errors} }, 0, 'collector-owned check-message no longer treats the mid-progress verbose edit failure as a terminal reply error' );
    is( $post_calls[0][0], 'sendChatAction', 'collector-owned check-message still starts typing before the managed reply path' );
    is( $post_calls[1][0], 'sendMessage', 'collector-owned check-message sends the initial verbose trace message before the edit failure' );
    is( $post_calls[2][0], 'editMessageText', 'collector-owned check-message still attempts the later verbose edit that fails non-fatally' );
    is( $post_calls[-1][0], 'sendMessage', 'collector-owned check-message still sends the final Telegram reply after the verbose progress failure' );
    is( $post_calls[-1][1]{text}, 'Reply still sent after progress-stream failure.', 'collector-owned check-message still delivers the Claude final reply after the verbose progress failure' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN               => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR       => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE     => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-emit-dies',
            TELEGRAM_CLAUDE_AUDIT             => '1',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 911,
                        message   => {
                            message_id => 73,
                            text       => 'Finish all tasks with all gates',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            };
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary, $args ) = @_;
            $args->{on_progress}->('step one') if $args->{on_progress};
            return 'Managed final reply after emit failure';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 700 + scalar @post_calls, chat => { id => $params->{chat_id} } },
            };
        },
    );
    {
        no warnings 'redefine';
        local *Telegram::Claude::Manager::start_listener_verbose_reporter = sub {
            return {
                emit   => sub { die "simulated reporter emit death\n" },
                finish => sub { return 1 },
            };
        };
        my $result = $manager->execute_check_messages( 'session-emit-dies', 1, 0 );
        is( $result->{processed}, 1, 'execute_check_messages still processes the update when the verbose reporter emit callback dies' );
        is( $result->{replied}, 1, 'execute_check_messages still delivers the final reply when the verbose reporter emit callback dies' );
        is( scalar @{ $result->{progress_errors} }, 1, 'execute_check_messages records the thrown verbose reporter emit failure as one progress error' );
        like( $result->{progress_errors}[0]{error}, qr/simulated reporter emit death/, 'execute_check_messages exposes the thrown verbose reporter emit failure detail' );
        is( $post_calls[-1][0], 'sendMessage', 'execute_check_messages still sends the final Telegram reply after the verbose reporter emit callback dies' );
    }
    my @rows = grep { defined $_ && $_ ne q{} } split /\n/, $manager->read_text_file( $manager->listener_paths_for_session('session-emit-dies')->{audit_file} );
    my @decoded = map { decode_json($_) } @rows;
    ok(
        scalar( grep { $_->{type} && $_->{type} eq 'progress.emit.failed' && $_->{error} =~ /simulated reporter emit death/ } @decoded ),
        'execute_check_messages records a progress.emit.failed audit row when the verbose reporter emit callback dies',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @resume_calls;
    my @post_calls;
    my @download_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 103,
                        message   => {
                            message_id => 21,
                            caption    => 'What is in this picture?',
                            chat       => { id => 99, type => 'private' },
                            photo      => [ { file_id => 'small-1' }, { file_id => 'big-photo-1' } ],
                        },
                    },
                ],
            } if $method eq 'getUpdates';
            return {
                ok     => JSON::XS::true,
                result => { file_path => 'photos/image-1.jpg' },
            } if $method eq 'getFile';
            die "unexpected method $method";
        },
        download_runner => sub {
            my ($url) = @_;
            push @download_calls, $url;
            return 'JPEGDATA';
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary ) = @_;
            push @resume_calls, [ $session_id, $prompt, $summary ];
            return 'Photo processed from local file.';
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 779, chat => { id => $params->{chat_id} }, text => $params->{text} },
            };
        },
    );
    $manager->write_claude_target_session_id( 'skills', 'session-from-ledger' );
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( $result->{processed}, 1, 'collector-owned check-message processes inbound photo messages' );
    is( scalar @download_calls, 1, 'collector-owned check-message downloads inbound managed media before asking Claude to reply' );
    like( $resume_calls[0][1], qr/photo_local_path=.*update-103.*photo-103\.jpg/, 'collector-owned check-message passes the downloaded photo local path into the Claude reply prompt' );
    like( $resume_calls[0][1], qr/already downloaded locally for this active Claude session/i, 'collector-owned check-message tells Claude the downloaded media is locally available' );
    is( $post_calls[-2][1]{text}, 'Photo processed from local file.', 'collector-owned check-message still sends the Claude-generated text reply after downloading photo media' );
}

{
    my $tmpdir = tempdir( CLEANUP => 1 );
    my $photo = File::Spec->catfile( $tmpdir, 'reply.png' );
    my $audio = File::Spec->catfile( $tmpdir, 'reply.mp3' );
    my $doc = File::Spec->catfile( $tmpdir, 'reply.pdf' );
    _write( $photo, 'png' );
    _write( $audio, 'mp3' );
    _write( $doc, 'pdf' );
    my @calls;
    my $manager = new_manager(
        post_runner => sub {
            my ( $method, $params, $files ) = @_;
            push @calls, [ $method, $params, $files ];
            return { ok => JSON::XS::true, result => { message_id => 800 + scalar @calls } };
        },
    );
    $manager->dispatch_listener_reply(
        chat_id             => 55,
        reply_to_message_id => 12,
        reply_message       => "telegram_attachment_type=photo\ntelegram_attachment_path=$photo\ntelegram_attachment_caption=look",
    );
    $manager->dispatch_listener_reply(
        chat_id             => 55,
        reply_to_message_id => 13,
        reply_message       => "telegram_attachment_type=audio\ntelegram_attachment_path=$audio\ntelegram_attachment_caption=listen",
    );
    $manager->dispatch_listener_reply(
        chat_id             => 55,
        reply_to_message_id => 14,
        reply_message       => "telegram_attachment_type=document\ntelegram_attachment_path=$doc\ntelegram_attachment_caption=read",
    );
    is( $calls[0][0], 'sendPhoto', 'dispatch_listener_reply routes photo attachment directives to sendPhoto' );
    is( $calls[0][2]{photo}, $photo, 'dispatch_listener_reply forwards the local photo path' );
    is( $calls[1][0], 'sendAudio', 'dispatch_listener_reply routes audio attachment directives to sendAudio' );
    is( $calls[1][2]{audio}, $audio, 'dispatch_listener_reply forwards the local audio path' );
    is( $calls[2][0], 'sendDocument', 'dispatch_listener_reply routes generic attachment directives to sendDocument' );
    is( $calls[2][2]{document}, $doc, 'dispatch_listener_reply forwards the local document path' );
}

{
    my $manager = new_manager;
    my $prompt = $manager->claude_session_reply_prompt(
        {
            message_id => 55,
            text       => q{},
            caption    => 'media caption',
            chat       => { id => 77 },
            photo      => { file_id => 'photo-1', local_path => '/tmp/photo-1.jpg' },
            document   => { file_id => 'doc-1', file_name => 'report.pdf', mime_type => 'application/pdf', local_path => '/tmp/report.pdf' },
            audio      => { file_id => 'aud-1', title => 'Track', mime_type => 'audio/mpeg', local_path => '/tmp/track.bin' },
            video      => { file_id => 'vid-1', mime_type => 'video/mp4', duration => 9, local_path => '/tmp/video.bin' },
            voice      => { file_id => 'voc-1', mime_type => 'audio/ogg', duration => 4, local_path => '/tmp/voice.bin' },
        }
    );
    like( $prompt, qr/Downloaded Telegram images are attached to this Claude prompt as real image inputs when available\./i, 'claude_session_reply_prompt tells Claude that supported Telegram images are attached as real image inputs' );
    like( $prompt, qr/Non-image files remain available through the local paths below for tool-based inspection\./i, 'claude_session_reply_prompt distinguishes local-path-only media from real image attachments' );
    like( $prompt, qr/already downloaded locally for this active Claude session/i, 'claude_session_reply_prompt tells Claude that local media paths are already downloaded' );
    like( $prompt, qr/Do not claim the attachment was not downloaded/i, 'claude_session_reply_prompt blocks the old metadata-only excuse when local paths exist' );
    like( $prompt, qr/photo_file_id=photo-1/, 'claude_session_reply_prompt includes inbound photo metadata for Telegram media handling' );
    like( $prompt, qr/photo_local_path=\/tmp\/photo-1\.jpg/, 'claude_session_reply_prompt includes inbound photo local path metadata' );
    like( $prompt, qr/document_file_id=doc-1/, 'claude_session_reply_prompt includes inbound document metadata' );
    like( $prompt, qr/document_name=report\.pdf/, 'claude_session_reply_prompt includes inbound document filename metadata' );
    like( $prompt, qr/document_local_path=\/tmp\/report\.pdf/, 'claude_session_reply_prompt includes inbound document local path metadata' );
    like( $prompt, qr/audio_file_id=aud-1/, 'claude_session_reply_prompt includes inbound audio metadata' );
    like( $prompt, qr/audio_local_path=\/tmp\/track\.bin/, 'claude_session_reply_prompt includes inbound audio local path metadata' );
    like( $prompt, qr/video_file_id=vid-1/, 'claude_session_reply_prompt includes inbound video metadata' );
    like( $prompt, qr/video_local_path=\/tmp\/video\.bin/, 'claude_session_reply_prompt includes inbound video local path metadata' );
    like( $prompt, qr/voice_file_id=voc-1/, 'claude_session_reply_prompt includes inbound voice metadata' );
    like( $prompt, qr/voice_local_path=\/tmp\/voice\.bin/, 'claude_session_reply_prompt includes inbound voice local path metadata' );
}

{
    my $manager = new_manager;
    my @paths = $manager->claude_session_image_input_paths(
        {
            photo    => { local_path => '/tmp/photo-1.jpg' },
            document => { file_name => 'preview.png', mime_type => 'image/png', local_path => '/tmp/preview.png' },
            audio    => { local_path => '/tmp/track.mp3' },
            voice    => { local_path => '/tmp/voice.ogg' },
        }
    );
    is_deeply( \@paths, [ '/tmp/photo-1.jpg', '/tmp/preview.png' ], 'claude_session_image_input_paths returns only photo and image-document local paths' );
}

{
    my $manager = new_manager;
    my @paths = $manager->claude_session_image_input_paths(
        {
            document => { file_name => 'Report Final.PDF', mime_type => 'application/pdf', local_path => '/tmp/report.pdf' },
            video    => { local_path => '/tmp/video.mp4' },
        }
    );
    is_deeply( \@paths, [], 'claude_session_image_input_paths excludes non-image local files' );
}

{
    my $manager = new_manager;
    my $prompt = $manager->claude_session_reply_prompt(
        {
            message_id => 77,
            text       => 'Finish all tasks with all gates',
            caption    => q{},
            chat       => { id => 88 },
        }
    );
    like( $prompt, qr/Do the actual work in this resumed Claude session before you reply/i, 'task-style Telegram prompts tell Claude to do the work before replying' );
    like( $prompt, qr/Do not prepend greetings, acknowledgements, or status prefaces/i, 'task-style Telegram prompts block boilerplate prefaces' );
    like( $prompt, qr/Do not send promise-only replies such as .*will be done/i, 'task-style Telegram prompts block promise-only placeholder replies' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $session_id = '019e-session-sync-demo';
    my $session_dir = File::Spec->catdir( $runtime, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    my @rows = (
        {
            timestamp => '2026-05-22T10:00:00Z',
            type      => 'user',
            message   => {
                role    => 'user',
                content => [
                    {
                        type => 'text',
                        text => 'TUI side says hello',
                    },
                ],
            },
        },
        {
            timestamp => '2026-05-22T10:00:10Z',
            type      => 'assistant',
            message   => {
                role    => 'assistant',
                content => [
                    {
                        type => 'text',
                        text => 'TUI side replied hello',
                    },
                ],
            },
        },
        {
            timestamp => '2026-05-22T10:01:00Z',
            type      => 'user',
            message   => {
                role    => 'user',
                content => [
                    {
                        type => 'text',
                        text => join(
                            "\n",
                            'A Telegram user sent a message to this active Claude session.',
                            'Reply as this Claude session, using the current conversation context.',
                            'chat_id=398296603',
                            'message_id=77',
                            'text=Telegram asks here',
                            'caption=',
                        ),
                    },
                ],
            },
        },
    );
    _write( $session_file, join( q{}, map { encode_json($_) . "\n" } @rows ) );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => $session_id,
            TELEGRAM_CLAUDE_SESSION_ID        => 'skills',
        },
    );
    my @messages = $manager->claude_session_recent_messages($session_id);
    is( $messages[0]{text}, 'TUI side says hello', 'claude_session_recent_messages keeps normal TUI user messages' );
    is( $messages[1]{text}, 'TUI side replied hello', 'claude_session_recent_messages keeps normal TUI assistant messages' );
    is( $messages[2]{text}, "[Telegram chat 398296603 message 77]\nTelegram asks here", 'claude_session_recent_messages normalizes old raw Telegram bridge prompts into readable transcript lines' );
    my $prompt = $manager->claude_session_reply_prompt(
        {
            message_id => 88,
            text       => 'Please continue from Telegram',
            caption    => q{},
            chat       => { id => 398296603 },
        }
    );
    like( $prompt, qr/Recent shared Claude session transcript:/, 'claude_session_reply_prompt includes recent persisted Claude transcript context' );
    like( $prompt, qr/user: TUI side says hello/, 'claude_session_reply_prompt carries recent TUI-side user history into Telegram replies' );
    like( $prompt, qr/assistant: TUI side replied hello/, 'claude_session_reply_prompt carries recent TUI-side assistant history into Telegram replies' );
    like( $prompt, qr/user: \[Telegram chat 398296603 message 77\]\nTelegram asks here/, 'claude_session_reply_prompt carries normalized older Telegram turns too' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $session_dir = File::Spec->catdir( $runtime, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
    );
    is( $manager->claude_session_transcript_path('019e-session-missing'), undef, 'claude_session_transcript_path returns undef when the Claude session tree exists but no matching transcript file is present' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $session_id = '019e-session-sync-write';
    my $session_dir = File::Spec->catdir( $runtime, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write( $session_file, q{} );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
    );
    my $summary = {
        message_id => 99,
        text       => 'Telegram asks from phone',
        caption    => q{},
        chat       => { id => 398296603 },
        document   => { file_name => 'report.pdf', local_path => '/tmp/report.pdf' },
    };
    ok( $manager->sync_telegram_exchange_to_claude_session( $session_id, $summary, 'Reply sent back to Telegram' ), 'sync_telegram_exchange_to_claude_session appends Telegram exchange rows into the target Claude session transcript' );
    ok( !$manager->sync_telegram_exchange_to_claude_session( $session_id, $summary, 'Reply sent back to Telegram' ), 'sync_telegram_exchange_to_claude_session deduplicates the same Telegram message marker on later runs' );
    my $content = $manager->read_text_file($session_file);
    like( $content, qr/\[Telegram chat 398296603 message 99\]\\nTelegram asks from phone\\n\[document\] \/tmp\/report\.pdf/s, 'sync_telegram_exchange_to_claude_session appends a readable Telegram user message into the Claude session file' );
    like( $content, qr/\[Telegram reply chat 398296603 message 99\]\\nReply sent back to Telegram/s, 'sync_telegram_exchange_to_claude_session appends the Telegram-facing assistant reply into the Claude session file' );
}

{
    my $manager = new_manager;
    my @lines = $manager->telegram_session_media_summary_lines(
        {
            photo => { local_path => '/tmp/photo.png' },
            audio => { title => 'demo tone' },
            video => { file_id => 'video-file-id' },
            voice => { file_id => 'voice-file-id' },
        }
    );
    is_deeply(
        \@lines,
        [
            '[photo] /tmp/photo.png',
            '[audio] demo tone',
            '[video] video-file-id',
            '[voice] voice-file-id',
        ],
        'telegram_session_media_summary_lines covers photo, audio, video, and voice attachment summary rows'
    );
}

{
    my $manager = new_manager;
    my @descriptors = $manager->summary_media_descriptors(
        {
            update_id => 500,
            document  => { file_id => 'doc-x', file_name => 'Quarterly Report (Final).pdf' },
            audio     => { file_id => 'aud-x', title => 'Track 01 / Intro' },
        }
    );
    is( $descriptors[0]{filename}, 'Quarterly-Report-Final-.pdf', 'summary_media_descriptors sanitizes inbound document filenames through safe_filename' );
    is( $descriptors[1]{filename}, 'Track-01-Intro.bin', 'summary_media_descriptors sanitizes inbound audio titles through safe_filename' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $runtime, 'bin' );
    make_path($bin_dir);
    my $args_file = File::Spec->catfile( $runtime, 'resume.args' );
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, <<"EOF" );
#!/bin/sh
printf '%s\n' "\$@" > "$args_file"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"session-real-resume"}'
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"/bin/pwd"}}]}}'
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"/tmp\\n"}]}}'
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Inspecting the local file"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","result":"  Live Claude Telegram reply.  ","session_id":"session-real-resume"}'
exit 0
EOF
    chmod 0755, $real_claude or die "Unable to chmod fake real claude --resume binary: $!";
    my @progress;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            VERSION                         => '0.30',
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            CLAUDE_SESSION_ID                => 'session-real-resume',
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-real-resume',
            CLAUDE_REAL_BIN                  => $real_claude,
        },
    );
    my $reply = $manager->claude_session_reply_for_update(
        {
            message_id => 14,
            text       => 'hello from telegram',
            chat       => { id => 88, type => 'private' },
            photo      => { file_id => 'photo-1', local_path => '/tmp/real-photo.jpg' },
            document   => { file_id => 'doc-1', file_name => 'preview.png', mime_type => 'image/png', local_path => '/tmp/preview.png' },
            voice      => { file_id => 'voc-1', local_path => '/tmp/voice.ogg' },
        },
        on_progress => sub { push @progress, @_ },
    );
    is( $reply, 'Live Claude Telegram reply.', 'claude_session_reply_for_update uses the real claude exec resume path and trims the generated reply text' );
    my $args = do {
        open my $fh, '<', $args_file or die $!;
        local $/;
        <$fh>;
    };
    like( $args, qr/^-p\n/m, 'claude_session_reply_for_update invokes claude print mode with the prompt argument first' );
    like( $args, qr/\n--resume\nsession-real-resume\n/s, 'claude_session_reply_for_update resumes the managed session id in print mode' );
    like( $args, qr/\n--output-format\nstream-json\n--verbose\n--dangerously-skip-permissions\n/s, 'claude_session_reply_for_update streams stream-json with verbose output and skips permission prompts' );
    like( $args, qr{telegram_image_local_path=/tmp/real-photo\.jpg}s, 'claude_session_reply_for_update references Telegram photo local paths in the prompt for the Claude Read tool' );
    like( $args, qr{telegram_image_local_path=/tmp/preview\.png}s, 'claude_session_reply_for_update references image documents in the prompt for the Claude Read tool' );
    unlike( $args, qr{telegram_image_local_path=/tmp/voice\.ogg}s, 'claude_session_reply_for_update does not reference non-image media as image inputs' );
    is_deeply(
        \@progress,
        [
            'Session resumed',
            'Running tool: Bash: /bin/pwd',
            'Output: /tmp',
            'Agent: Inspecting the local file',
            'Turn completed',
        ],
        'claude_session_reply_for_update streams real claude json events through the progress callback',
    );
    like( $manager->{ua}->agent, qr/\Atelegram-claude\/0\.30\z/, 'manager user agent tracks the current skill version' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $runtime, 'bin' );
    make_path($bin_dir);
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, <<"EOF" );
#!/bin/sh
echo "provider socket closed unexpectedly" >&2
exit 7
EOF
    chmod 0755, $real_claude or die "Unable to chmod fake failing real claude --resume binary: $!";
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-real-resume',
            CLAUDE_REAL_BIN                  => $real_claude,
        },
    );
    my $error = eval {
        $manager->claude_session_reply_for_update(
            {
                message_id => 18,
                text       => 'hello from telegram',
                chat       => { id => 88, type => 'private' },
            }
        );
        1;
    } ? q{} : $@;
    like( $error, qr/Claude resume returned an empty Telegram reply \(exit=7 signal=0\)/, 'claude_session_reply_for_update reports the real exit status when the managed claude --resume subprocess fails before writing a reply' );
    like( $error, qr/provider socket closed unexpectedly/, 'claude_session_reply_for_update includes stderr tail detail from the failed managed claude --resume subprocess' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $runtime, 'bin' );
    make_path($bin_dir);
    my $real_claude = File::Spec->catfile( $bin_dir, 'claude-real' );
    _write( $real_claude, <<"EOF" );
#!/bin/sh
printf '%s\n' '{"type":"system","subtype":"init"}'
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Long task step"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","result":"Final answer after progress callback failure"}'
exit 0
EOF
    chmod 0755, $real_claude or die "Unable to chmod fake callback-failing real claude --resume binary: $!";
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN               => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR       => $runtime,
            TELEGRAM_CLAUDE_LISTENER_MODE     => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-callback-failure',
            TELEGRAM_CLAUDE_AUDIT             => '1',
            CLAUDE_REAL_BIN                   => $real_claude,
        },
    );
    my $reply = $manager->claude_session_reply_for_update(
        {
            message_id => 41,
            text       => 'Finish all tasks with all gates',
            chat       => { id => 88, type => 'private' },
        },
        on_progress => sub { die "progress callback blew up\n" },
    );
    is( $reply, 'Final answer after progress callback failure', 'claude_session_reply_for_update still returns the final reply when the progress callback dies' );
    my @rows = grep { defined $_ && $_ ne q{} } split /\n/, $manager->read_text_file( $manager->listener_paths->{audit_file} );
    my @decoded = map { decode_json($_) } @rows;
    ok(
        scalar( grep { $_->{type} && $_->{type} eq 'claude.progress.callback_failed' && $_->{error} =~ /progress callback blew up/ } @decoded ),
        'claude_session_reply_for_update records a claude.progress.callback_failed audit event when the progress callback dies',
    );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @resume_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN              => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR      => $runtime,
            CLAUDE_SESSION_ID                => 'skills',
            TELEGRAM_CLAUDE_SESSION_ID       => 'skills',
            TELEGRAM_CLAUDE_LISTENER_MODE    => 'claude-session',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => 'session-real-resume',
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary ) = @_;
            push @resume_calls, [ $session_id, $prompt, $summary ];
            return @resume_calls == 1 ? 'Will be done.' : 'Done. All requested tasks are now complete.';
        },
    );
    my $reply = $manager->claude_session_reply_for_update(
        {
            message_id => 15,
            text       => 'Finish all tasks with all gates',
            chat       => { id => 88, type => 'private' },
        }
    );
    is( scalar @resume_calls, 2, 'claude_session_reply_for_update retries once when the first task reply is only a promise placeholder' );
    like( $resume_calls[1][1], qr/The prior reply was only a promise or progress update/i, 'claude_session_reply_for_update uses a stricter retry prompt after a promise-only reply' );
    is( $reply, 'Done. All requested tasks are now complete.', 'claude_session_reply_for_update returns the stricter retry result instead of the placeholder promise' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $config_root = File::Spec->catdir( $home, '.developer-dashboard', 'config' );
    make_path($config_root);
    _write(
        File::Spec->catfile( $config_root, 'claude.json' ),
        encode_json(
            {
                talbot       => 'session-talbot-42',
                _last_action => 'Add talbot',
                _last_update => '2026-05-21 08:00:00',
            }
        ),
    );
    my @resume_calls;
    my $manager = new_manager(
        cwd  => File::Spec->catdir( $home, 'talbot' ),
        home => $home,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => '~/.telegram-claude',
            TELEGRAM_CLAUDE_SESSION_ID  => 'skills',
            CLAUDE_SESSION_ID           => 'skills',
            TICKET_REF                 => 'skills',
        },
        claude_resume_runner => sub {
            my ( $session_id, $prompt, $summary ) = @_;
            push @resume_calls, [ $session_id, $prompt, $summary ];
            return 'Mapped saved-session reply.';
        },
    );
    my $reply = $manager->claude_session_reply_for_update(
        {
            message_id => 16,
            text       => 'status?',
            chat       => { id => 99, type => 'private' },
        }
    );
    is( $resume_calls[0][0], 'session-talbot-42', 'claude_session_reply_for_update falls back to claude.json saved-session mapping when claude.session is missing' );
    is( $reply, 'Mapped saved-session reply.', 'claude_session_reply_for_update returns the mapped-session response' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @get_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-rate-limited',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 55,
                        message   => {
                            message_id => 21,
                            text       => 'hello',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            } if @get_calls == 1;
            return { ok => JSON::XS::true, result => [] };
        },
        post_runner => sub {
            die "Telegram POST failed for sendMessage: 429 Too Many Requests\n";
        },
    );
    my $result = $manager->execute_listen( 2, 0, 'listener ack' );
    is( $result->{processed}, 1, 'listen still records inbound messages when reply send fails' );
    is( $result->{replied}, 0, 'listen does not count failed reply sends as successful replies' );
    is( scalar @{ $result->{reply_errors} }, 1, 'listen reports reply-send failures instead of dying before state is saved' );
    is( $manager->read_text_file( $result->{offset_file} ), "56\n", 'listen still persists the next offset after a reply-send failure so the same message is not retried forever' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @sleep_calls;
    my $get_call_count = 0;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-get-retry',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            $get_call_count++;
            die "Telegram GET failed for getUpdates: 500 Status read failed: Connection reset by peer\n" if $get_call_count == 1;
            return {
                ok     => JSON::XS::true,
                result => $get_call_count == 2
                  ? [
                        {
                            update_id => 71,
                            message   => {
                                message_id => 10,
                                text       => 'hello',
                                chat       => { id => 88, type => 'private' },
                            },
                        },
                    ]
                  : [],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => { message_id => 400 + scalar @post_calls, chat => { id => $params->{chat_id} } },
            };
        },
        sleep_runner => sub {
            my ($seconds) = @_;
            push @sleep_calls, $seconds;
        },
    );
    my $result = $manager->execute_listen( 3, 0, 'listener ack' );
    is( $result->{processed}, 1, 'listen survives a transient getUpdates transport failure and still processes later messages' );
    is( $result->{replied}, 1, 'listen still replies after recovering from a transient getUpdates transport failure' );
    is( scalar @{ $result->{get_errors} }, 1, 'listen reports the transient getUpdates transport failure' );
    is( $result->{get_errors}[0]{cycle}, 0, 'listen records the failed cycle index for the transient getUpdates transport failure' );
    is( scalar @sleep_calls, 1, 'listen pauses once before retrying after a transient getUpdates transport failure' );
    is( $manager->read_text_file( $result->{offset_file} ), "72\n", 'listen still advances and persists the next offset after recovering from a transient getUpdates transport failure' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @call_order;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-outbound-order',
        },
        get_runner => sub {
            push @call_order, 'getUpdates';
            die "Telegram GET failed for getUpdates: 500 Status read failed: Connection reset by peer\n";
        },
    );
    local *Telegram::Claude::Manager::process_tui_live_outbound_transcript = sub {
        push @call_order, 'process_tui';
        return 0;
    };
    my $result = $manager->execute_check_messages( 'skills', 1, 0 );
    is( scalar @{ $result->{get_errors} }, 1, 'execute_check_messages still records the transient getUpdates failure while polling shared TUI transcript state first' );
    is_deeply( \@call_order, [ 'process_tui', 'getUpdates' ], 'execute_check_messages services the shared TUI transcript before a failing getUpdates poll' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @get_calls;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN                   => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR           => $runtime,
            CLAUDE_SESSION_ID                     => 'session-prime-latest',
            TELEGRAM_CLAUDE_LISTENER_PRIME_LATEST => '1',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, { %{$params} } ];
            return {
                ok     => JSON::XS::true,
                result => !defined $params->{offset}
                  ? [
                        { update_id => 90, message => { message_id => 1, text => 'old one', chat => { id => 88, type => 'private' } } },
                        { update_id => 91, message => { message_id => 2, text => 'old two', chat => { id => 88, type => 'private' } } },
                    ]
                  : [],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => { message_id => 1 } };
        },
    );
    my $result = $manager->execute_listen( 1, 0 );
    is( $result->{processed}, 0, 'prime-latest auto-start does not process old backlog messages on the first cycle' );
    is( $result->{replied}, 0, 'prime-latest auto-start does not reply to old backlog messages' );
    is( $manager->read_text_file( $result->{offset_file} ), "92\n", 'prime-latest auto-start persists the primed next offset' );
    is( scalar @post_calls, 0, 'prime-latest auto-start does not send message replies for old backlog items' );
    is_deeply( $get_calls[0][1], { limit => 100, timeout => 0 }, 'prime-latest auto-start first scans the pending Telegram backlog without an offset' );
    is_deeply( $get_calls[1][1], { limit => 20, timeout => 0, offset => 92 }, 'prime-latest auto-start begins normal listening from the primed offset' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @get_calls;
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN                   => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR           => $runtime,
            CLAUDE_SESSION_ID                     => 'session-prime-then-capture',
            TELEGRAM_CLAUDE_LISTENER_PRIME_LATEST => '1',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, { %{$params} } ];
            return {
                ok     => JSON::XS::true,
                result => !defined $params->{offset}
                  ? [
                        { update_id => 100, message => { message_id => 1, text => 'old one', chat => { id => 88, type => 'private' } } },
                        { update_id => 101, message => { message_id => 2, text => 'old two', chat => { id => 88, type => 'private' } } },
                    ]
                  : [
                        { update_id => 102, message => { message_id => 3, text => 'new one', chat => { id => 88, type => 'private' } } },
                    ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => { message_id => 200 } };
        },
    );
    my $result = $manager->execute_listen( 1, 0 );
    is( $result->{processed}, 1, 'prime-latest auto-start still processes new messages after priming the old backlog away' );
    is( $result->{replied}, 0, 'prime-latest auto-start does not auto-reply by default after priming' );
    is( $manager->read_text_file( $result->{offset_file} ), "103\n", 'prime-latest auto-start advances offset after the new message cycle' );
    is( scalar @post_calls, 0, 'prime-latest auto-start only captures the new message unless a reply text is explicitly provided' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $session_dir = File::Spec->catdir( $runtime, 'session-skip-duplicate' );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    mkdir $session_dir;
    make_path($shared_root);
    _write(
        File::Spec->catfile( $shared_root, 'listener.inbox.jsonl' ),
        encode_json(
            {
                update_id  => 500,
                message_id => 21,
                text       => 'already seen',
            }
        ) . "\n",
    );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-skip-duplicate',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 500,
                        message   => {
                            message_id => 21,
                            text       => 'already seen',
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => { message_id => 61 } };
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 0, 'listen skips an update already present in the session inbox ledger' );
    is( $result->{replied}, 0, 'listen does not reply again for an update already present in the session inbox ledger' );
    is( scalar @post_calls, 0, 'listen suppresses duplicate reply sends for an already-recorded update' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $polls = 0;
    my $slept = 0;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-zero-means-forever',
        },
        get_runner => sub {
            $polls++;
            die "forced listener stop\n" if $polls > 1;
            return { ok => JSON::XS::true, result => [] };
        },
        sleep_runner => sub {
            $slept++;
            die "listener paused after retry\n";
        },
    );
    my $error = eval { $manager->execute_listen( 0, 0 ); 1 } ? q{} : $@;
    like( $error, qr/listener paused after retry/, 'listen treats MAX_CYCLES=0 as run forever instead of exiting after the first cycle' );
    is( $polls, 2, 'listen performs another poll cycle before external stop when MAX_CYCLES=0 is passed' );
    is( $slept, 1, 'listen reaches the retry pause path instead of terminating immediately when MAX_CYCLES=0 is passed' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    make_path($shared_root);
    _write( File::Spec->catfile( $shared_root, 'listener.offset' ), "50\n" );
    my @get_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-resume',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => [] };
        },
        post_runner => sub {
            die 'listen should not reply when no new updates are present';
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 0, 'listen handles empty cycles cleanly' );
    is( $get_calls[0][1]{offset}, 50, 'listen resumes from stored offset on restart' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    make_path($shared_root);
    _write(
        File::Spec->catfile( $shared_root, 'listener.inbox.jsonl' ),
        join(
            "\n",
            encode_json( { update_id => 120, text => 'old-1' } ),
            encode_json( { update_id => 121, text => 'old-2' } ),
            q{},
        ),
    );
    my @get_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-recover',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => [] };
        },
        post_runner => sub {
            die 'listen should not reply when no new updates are present';
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 0, 'listen can recover an offset from the inbox ledger when the offset file is missing' );
    is( $get_calls[0][1]{offset}, 122, 'listen resumes from the recovered next offset when only the inbox ledger exists' );
    is( $manager->read_text_file( File::Spec->catfile( $shared_root, 'listener.offset' ) ), "122\n", 'listen persists the recovered next offset back to the token-scoped shared listener.offset when the file was missing' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    make_path($shared_root);
    _write( File::Spec->catfile( $shared_root, 'listener.offset' ), "50\n" );
    _write(
        File::Spec->catfile( $shared_root, 'listener.inbox.jsonl' ),
        join(
            "\n",
            encode_json( { update_id => 120, text => 'old-1' } ),
            encode_json( { update_id => 121, text => 'old-2' } ),
            q{},
        ),
    );
    my @get_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-recover-newer',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => [] };
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 0, 'listen handles stale stored offsets cleanly when the inbox ledger proves a newer offset' );
    is( $get_calls[0][1]{offset}, 122, 'listen advances to the newer recovered inbox offset instead of replaying from an older stored offset' );
    is( $manager->read_text_file( File::Spec->catfile( $shared_root, 'listener.offset' ) ), "122\n", 'listen rewrites the token-scoped shared listener.offset to the newer recovered inbox offset before polling' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    make_path($shared_root);
    _write(
        File::Spec->catfile( $shared_root, 'listener.inbox.jsonl' ),
        join(
            "\n",
            'not-json-at-all',
            encode_json( { text => 'missing update id' } ),
            q{},
        ),
    );
    my @get_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-recover-invalid',
        },
        get_runner => sub {
            my ( $method, $params ) = @_;
            push @get_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => [] };
        },
        post_runner => sub {
            die 'listen should not reply when no new updates are present';
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 0, 'listen handles an invalid inbox ledger without crashing when no offset file exists' );
    ok( !exists $get_calls[0][1]{offset}, 'listen leaves the offset unset when inbox recovery finds no valid update id' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $shared_root = File::Spec->catdir( $runtime, '.shared', Digest::SHA::sha1_hex('token-xyz') );
    make_path($shared_root);
    _write( File::Spec->catfile( $shared_root, 'listener.offset' ), "50\n" );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-skip-stale',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    { update_id => 48, message => { message_id => 1, text => 'too old', chat => { id => 88, type => 'private' } } },
                    { update_id => 49, message => { message_id => 2, text => 'still old', chat => { id => 88, type => 'private' } } },
                    { update_id => 50, message => { message_id => 3, text => 'current', chat => { id => 88, type => 'private' } } },
                    { update_id => 51, message => { message_id => 4, text => 'newer', chat => { id => 88, type => 'private' } } },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => { message_id => 300 + scalar @post_calls } };
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 2, 'listen skips stale returned updates that are older than the next stored offset' );
    is( $result->{replied}, 2, 'listen only replies to non-stale updates' );
    is( $manager->read_text_file( $result->{offset_file} ), "52\n", 'listen still advances offset after the non-stale updates' );
    my @entries = split /\n/, $manager->read_text_file( $result->{inbox_file} );
    is( scalar @entries, 2, 'listen appends only the non-stale updates to the inbox ledger' );
    is( decode_json( $entries[0] )->{update_id}, 50, 'listen keeps the first current update' );
    is( decode_json( $entries[1] )->{update_id}, 51, 'listen keeps the newer update' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-no-reply',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 77,
                        message   => {
                            message_id => 12,
                            chat       => { id => 88, type => 'private' },
                        },
                    },
                ],
            };
        },
        post_runner => sub {
            push @post_calls, [@_];
            return { ok => JSON::XS::true, result => { message_id => 1, chat => { id => 88 } } };
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 1, 'listen still logs non-replied updates' );
    is( scalar @post_calls, 0, 'listen skips auto-reply for unsupported message kinds' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $runtime,
        home => $runtime,
        env  => {
            TELEGRAM_BOT_TOKEN         => 'token-xyz',
            TELEGRAM_CLAUDE_RUNTIME_DIR => $runtime,
            CLAUDE_SESSION_ID           => 'session-media',
        },
        get_runner => sub {
            return {
                ok     => JSON::XS::true,
                result => [
                    {
                        update_id => 81,
                        message   => {
                            message_id => 13,
                            chat       => { id => 88, type => 'private' },
                            audio      => { file_id => 'audio-2' },
                        },
                    },
                    {
                        update_id => 82,
                        message   => {
                            message_id => 14,
                            chat       => { id => 88, type => 'private' },
                            video      => { file_id => 'video-2' },
                        },
                    },
                    {
                        update_id => 83,
                        message   => {
                            message_id => 15,
                            chat       => { id => 88, type => 'private' },
                            voice      => { file_id => 'voice-2' },
                        },
                    },
                ],
            };
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return { ok => JSON::XS::true, result => { message_id => 50 + scalar @post_calls, chat => { id => $params->{chat_id} } } };
        },
    );
    my $result = $manager->execute_listen( 1, 0, 'listener ack' );
    is( $result->{processed}, 3, 'listen processes audio, video, and voice updates' );
    is( scalar @post_calls, 3, 'listen replies to audio, video, and voice updates' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        home => $home,
        env  => {
            CLAUDE_PRIMARY_PLUGIN_ROOT         => '~/primary/plugins',
            CLAUDE_PRIMARY_MARKETPLACE_PATH    => '~/primary/marketplace.json',
            CLAUDE_MIRROR_PLUGIN_ROOT          => '~/mirror/plugins',
            CLAUDE_MIRROR_MARKETPLACE_PATH     => '~/mirror/marketplace.json',
        },
    );
    make_path( File::Spec->catdir( $home, 'mirror' ) );
    my @targets = $manager->plugin_targets;
    is( scalar @targets, 2, 'plugin targets include mirror path when mirror base exists' );
}

{
    my $manager = new_manager;
    is( $manager->listener_pause_seconds(0), 0, 'listener_pause_seconds returns after the direct sleep path without requiring an injected sleep runner' );
}

{
    my $cwd = tempdir( CLEANUP => 1 );
    _write(
        File::Spec->catfile( $cwd, '.env' ),
        "TELEGRAM_BOT_TOKEN=file-token\nKEEP=value\n",
    );
    local $ENV{TELEGRAM_BOT_TOKEN} = q{};
    my $manager = Telegram::Claude::Manager->new(
        cwd  => $cwd,
        home => '/tmp/test-home',
    );
    is( $manager->env_value('KEEP'), 'value', 'merged env loads values from local .env file' );
    is( $manager->resolve_token(), 'file-token', 'resolve_token falls back to loaded .env token' );
    is( $manager->resolve_path(undef), undef, 'resolve_path preserves undefined value' );
    is( $manager->resolve_path('~'), '/tmp/test-home', 'resolve_path expands bare tilde to home' );
    is( $manager->resolve_path('relative/path.txt'), 'relative/path.txt', 'resolve_path leaves plain paths unchanged' );
    is( $manager->basename('dir\\file.txt'), 'file.txt', 'basename normalizes windows separators' );
}

{
    my $cwd = tempdir( CLEANUP => 1 );
    _write(
        File::Spec->catfile( $cwd, '.env' ),
        "TELEGRAM_BOT_TOKEN=file-token\nTELEGRAM_CLAUDE_RUNTIME_DIR=/tmp/isolated-runtime\n",
    );
    local $ENV{TELEGRAM_BOT_TOKEN} = 'shell-token';
    local $ENV{TELEGRAM_CLAUDE_RUNTIME_DIR} = '/tmp/shared-runtime';
    my $manager = Telegram::Claude::Manager->new(
        cwd  => $cwd,
        home => '/tmp/test-home',
    );
    is( $manager->resolve_token(), 'file-token', 'merged env gives the nearest workspace .env priority over inherited TELEGRAM_BOT_TOKEN values' );
    is( $manager->env_value('TELEGRAM_CLAUDE_RUNTIME_DIR'), '/tmp/isolated-runtime', 'merged env gives the nearest workspace .env priority over inherited TELEGRAM_CLAUDE_RUNTIME_DIR values' );
}

{
    my $cwd = tempdir( CLEANUP => 1 );
    _write(
        File::Spec->catfile( $cwd, '.env' ),
        "# comment should be ignored\nTELEGRAM_BOT_TOKEN=file-token\nTELEGRAM_BOT_TOKEN=ignored-duplicate\n",
    );
    local $ENV{TELEGRAM_BOT_TOKEN} = 'shell-token';
    my $manager = Telegram::Claude::Manager->new(
        cwd  => $cwd,
        home => '/tmp/test-home',
    );
    is( $manager->resolve_token(), 'file-token', 'merged env keeps the first valid workspace .env value when duplicate keys appear later in the same file' );
}

{
    my $root = tempdir( CLEANUP => 1 );
    my $project = File::Spec->catdir( $root, 'project', 'app' );
    make_path($project);
    _write( File::Spec->catfile( $root, '.env' ), "TELEGRAM_BOT_TOKEN=root-token\n" );
    local $ENV{TELEGRAM_BOT_TOKEN} = q{};
    my $manager = Telegram::Claude::Manager->new(
        cwd  => $project,
        home => $root,
    );
    is( $manager->resolve_token(), 'root-token', 'resolve_token discovers TELEGRAM_BOT_TOKEN from a parent project .env' );
}

{
    my $root = tempdir( CLEANUP => 1 );
    my $project = File::Spec->catdir( $root, 'project' );
    my $skill_root = File::Spec->catdir( $root, 'skill-root' );
    make_path($project);
    make_path($skill_root);
    _write( File::Spec->catfile( $skill_root, '.env' ), "TELEGRAM_BOT_TOKEN=skill-token\n" );
    local $ENV{TELEGRAM_BOT_TOKEN} = q{};
    my $manager = Telegram::Claude::Manager->new(
        cwd        => $project,
        home       => $root,
        skill_root => $skill_root,
    );
    is( $manager->resolve_token(), 'skill-token', 'resolve_token falls back to skill-level .env when project .env is absent' );
}

{
    my $tmpdir = tempdir( CLEANUP => 1 );
    my $doc = File::Spec->catfile( $tmpdir, 'doc.txt' );
    _write( $doc, 'document' );
    my $ua = TestUA->new(
        request_queue => [
            TestResponse->new(
                is_success      => 1,
                decoded_content => encode_json( { ok => JSON::XS::true, result => { id => 1 } } ),
            ),
            TestResponse->new(
                is_success      => 1,
                decoded_content => encode_json( { ok => JSON::XS::true, result => { sent => JSON::XS::true } } ),
            ),
            TestResponse->new(
                is_success      => 1,
                decoded_content => encode_json( { ok => JSON::XS::true, result => { sent => JSON::XS::true } } ),
            ),
            TestResponse->new(
                is_success      => 1,
                decoded_content => encode_json( { ok => JSON::XS::true, result => { uploaded => JSON::XS::true } } ),
            ),
        ],
        get_queue => [
            TestResponse->new(
                is_success      => 1,
                decoded_content => 'FILEDATA',
            ),
        ],
    );
    my $manager = Telegram::Claude::Manager->new(
        cwd  => $tmpdir,
        home => '/tmp/test-home',
        env  => { TELEGRAM_BOT_TOKEN => 'abc123' },
        ua   => $ua,
    );
    is( $manager->telegram_api_base, 'https://api.telegram.org/botabc123', 'telegram_api_base builds bot API root' );
    is( $manager->telegram_file_base, 'https://api.telegram.org/file/botabc123', 'telegram_file_base builds file API root' );
    is( $manager->telegram_get('getMe')->{result}{id}, 1, 'telegram_get uses UA request path' );
    is(
        $manager->telegram_get( 'getFile', { file_id => 'photo-123', offset => 9 } )->{result}{sent},
        1,
        'telegram_get returns payload for parameterized GET requests',
    );
    is( $manager->telegram_post( 'sendMessage', { chat_id => 9 } )->{result}{sent}, 1, 'telegram_post uses UA request path' );
    is( $manager->telegram_post_file( 'sendDocument', { chat_id => 9 }, { document => $doc } )->{result}{uploaded}, 1, 'telegram_post_file uses multipart request path' );
    is( $manager->telegram_download('files/doc.txt'), 'FILEDATA', 'telegram_download uses UA get path' );
    is( $ua->{requests}[0]->method, 'GET', 'telegram_get sends GET request' );
    like( $ua->{requests}[1]->uri->query, qr/(?:^|&)file_id=photo-123(?:&|$)/, 'telegram_get encodes file_id into the query string' );
    like( $ua->{requests}[1]->uri->query, qr/(?:^|&)offset=9(?:&|$)/, 'telegram_get encodes numeric parameters into the query string' );
    ok( !$ua->{requests}[1]->header('File-Id'), 'telegram_get does not mis-send file_id as a header' );
    is( $ua->{requests}[2]->method, 'POST', 'telegram_post sends POST request' );
    is( $ua->{requests}[3]->method, 'POST', 'telegram_post_file sends multipart POST request' );
    like( $ua->{gets}[0][0], qr{/file/botabc123/files/doc\.txt$}, 'telegram_download fetches file URL' );
}

{
    my $cwd = tempdir( CLEANUP => 1 );
    my $manager = new_manager(
        cwd  => $cwd,
        home => $cwd,
        env  => { TELEGRAM_BOT_TOKEN => 'token-xyz' },
    );
    my $marketplace = File::Spec->catfile( $cwd, 'marketplace.json' );
    _write(
        $marketplace,
        encode_json(
            {
                name      => 'local-plugins',
                interface => { displayName => 'Local plugins' },
                plugins   => [
                    {
                        name     => 'telegram-claude',
                        source   => { source => 'local', path => './plugins/old' },
                        policy   => { installation => 'HIDDEN', authentication => 'NONE' },
                        category => 'Old',
                    },
                    {
                        name   => 'another-plugin',
                        source => { source => 'local', path => './plugins/another' },
                    },
                ],
            }
        ),
    );
    $manager->update_marketplace($marketplace);
    my $updated = decode_json( $manager->read_text_file($marketplace) );
    is( scalar @{ $updated->{plugins} }, 2, 'update_marketplace updates existing entry without duplication' );
    is( $updated->{plugins}[0]{source}{path}, './plugins/telegram-claude', 'update_marketplace refreshes existing telegram-claude entry' );
    is( $updated->{plugins}[1]{name}, 'another-plugin', 'update_marketplace keeps unrelated plugins' );
}

{
    my $manager = new_manager(
        process_list_runner => sub {
            return [
                {
                    pid => 1920363,
                    tty => 'pts/34',
                    cmd => '/opt/claude/bin/claude --resume 019e-live-shared-session',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id => '%118',
                    tty     => '/dev/pts/34',
                },
            ];
        },
    );
    is( $manager->discover_claude_session_tty('019e-live-shared-session'), 'pts/34', 'discover_claude_session_tty finds the tty for the live shared Claude session' );
    is( $manager->resolve_claude_live_tmux_pane('019e-live-shared-session'), '%118', 'resolve_claude_live_tmux_pane maps the live shared Claude session to its tmux pane' );
}

{
    my @sent;
    my $manager = new_manager(
        tmux_send_runner => sub {
            my ( $pane_id, $text ) = @_;
            push @sent, [ $pane_id, $text ];
            return 1;
        },
    );
    ok( $manager->tmux_send_text_to_pane( '%118', 'Remember this code abc:foo' ), 'tmux_send_text_to_pane succeeds through the injected tmux sender' );
    is_deeply( \@sent, [ [ '%118', 'Remember this code abc:foo' ] ], 'tmux_send_text_to_pane forwards the pane id and literal text to tmux' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-pane-session';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write( $session_file, q{} );
    my @progress;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => $session_id,
        },
        process_list_runner => sub {
            return [
                {
                    pid => 1920363,
                    tty => 'pts/34',
                    cmd => "/opt/claude/bin/claude --resume $session_id",
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id => '%118',
                    tty     => '/dev/pts/34',
                },
            ];
        },
        tmux_send_runner => sub {
            my ( $pane_id, $text ) = @_;
            open my $fh, '>>', $session_file or die "Unable to append $session_file: $!";
            print {$fh} encode_json(
                {
                    timestamp => '2026-05-22T18:30:01Z',
                    type      => 'user',
            message   => {
                role    => 'user',
                content => [
                            {
                                type => 'text',
                                text => $text,
                            },
                        ],
                    },
                }
            ) . "\n";
            print {$fh} encode_json(
                {
                    timestamp => '2026-05-22T18:30:02Z',
                    type      => 'assistant',
                    phase     => 'commentary',
                    message   => {
                        role    => 'assistant',
                        content => [
                            {
                                type => 'text',
                                text => 'Checking the live shared Claude session now.',
                            },
                        ],
                    },
                }
            ) . "\n";
            print {$fh} encode_json(
                {
                    timestamp => '2026-05-22T18:30:03Z',
                    type      => 'assistant',
                    phase     => 'final_answer',
                    message   => {
                        role    => 'assistant',
                        content => [
                            {
                                type => 'text',
                                text => 'Final live shared Claude reply.',
                            },
                        ],
                    },
                }
            ) . "\n";
            close $fh or die "Unable to close $session_file: $!";
            return 1;
        },
        claude_resume_runner => sub { die "live pane path should not fall back to claude exec resume\n" },
        sleep_runner        => sub { return 0 },
    );
    my $reply = $manager->claude_session_reply_for_update(
        {
            text       => 'Remember this code abc:foo',
            chat       => { id => 398296603 },
            message_id => 91,
        },
        on_progress => sub {
            my ($line) = @_;
            push @progress, $line;
            return 1;
        },
    );
    is( $reply, 'Final live shared Claude reply.', 'claude_session_reply_for_update returns the final assistant reply from the shared live transcript when a live tmux pane exists' );
    is_deeply( \@progress, [ 'Checking the live shared Claude session now.' ], 'claude_session_reply_for_update streams commentary rows from the shared live transcript as progress' );
    my $cursor_file = $manager->listener_paths->{transcript_cursor_file};
    ok( -f $cursor_file, 'claude_session_reply_for_update records the shared transcript cursor after consuming a live pane turn' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-fallback';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write( $session_file, q{} );
    my @resume_calls;
    my @sleep_calls;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_SESSION_ID        => 'skills',
            TELEGRAM_CLAUDE_TARGET_SESSION_ID => $session_id,
            TELEGRAM_CLAUDE_AUDIT             => '1',
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 44,
                    tty    => 'pts/0',
                    etimes => 90_000,
                    cmd    => "claude --resume $session_id",
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%77',
                    tty             => '/dev/pts/0',
                    current_command => 'node',
                },
            ];
        },
        tmux_send_runner => sub { return 1 },
        sleep_runner     => sub { push @sleep_calls, 1; return 0 },
        claude_resume_runner => sub {
            my ( $sid, $prompt ) = @_;
            push @resume_calls, [ $sid, $prompt ];
            return 'Detached fallback reply.';
        },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    my $reply = $manager->claude_session_reply_for_update(
        {
            text       => 'Test live pane fallback',
            chat       => { id => 398296603 },
            message_id => 92,
        },
    );
    is( $manager->resolve_claude_live_tmux_pane($session_id), '%77', 'claude_session_reply_for_update fallback test resolves the live pane first' );
    is( $reply, 'Detached fallback reply.', 'claude_session_reply_for_update falls back to detached resume when the live pane never records the injected turn' );
    is( scalar @resume_calls, 1, 'claude_session_reply_for_update retries through the detached resume path after live pane failure' );
    ok( !-f $manager->listener_paths->{transcript_cursor_file}, 'claude_session_reply_for_update fallback test does not falsely record a completed live transcript cursor' );
    my $audit = $manager->read_text_file( $manager->listener_paths->{audit_file} );
    like( $audit, qr/"type":"claude\.live_pane\.fallback"/, 'claude_session_reply_for_update records the live-pane fallback audit event' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-outbound-session';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_SESSION_ID => 'skills',
        },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write(
        $session_file,
        join(
            "\n",
            encode_json(
                {
                    timestamp => '2026-05-22T18:31:01Z',
                    type      => 'user',
            message   => {
                role    => 'user',
                content => [
                            {
                                type => 'text',
                                text => 'Please tighten these tests.',
                            },
                        ],
                    },
                }
            ),
            encode_json(
                {
                    timestamp => '2026-05-22T18:31:02Z',
                    type      => 'assistant',
                    phase     => 'commentary',
                    message   => {
                        role    => 'assistant',
                        content => [
                            {
                                type => 'text',
                                text => 'Reviewing the current test suite now.',
                            },
                        ],
                    },
                }
            ),
            encode_json(
                {
                    timestamp => '2026-05-22T18:31:03Z',
                    type      => 'assistant',
                    phase     => 'final_answer',
                    message   => {
                        role    => 'assistant',
                        content => [
                            {
                                type => 'text',
                                text => 'Tests tightened and rerun.',
                            },
                        ],
                    },
                }
            ),
            q{},
        ),
    );
    _write(
        File::Spec->catfile( $runtime_dir, 'pairing.json' ),
        encode_json( { paired_chat_id => 398296603 } ),
    );
    _write(
        File::Spec->catfile( $runtime_dir, 'claude.session' ),
        "$session_id\n",
    );
    _write(
        File::Spec->catfile( $runtime_dir, 'transcript.cursor' ),
        "0\n",
    );
    my @post_calls;
    my @typing_events;
    $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_SESSION_ID => 'skills',
        },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => {
                    message_id => 700 + scalar @post_calls,
                    chat       => { id => $params->{chat_id} },
                },
            };
        },
        typing_guard_runner => sub {
            my ( $summary, $self ) = @_;
            push @typing_events, 'guard-start';
            return sub {
                push @typing_events, 'guard-stop';
                return 1;
            };
        },
    );
    my %state;
    my $paths = $manager->listener_paths_for_session('skills');
    is( $manager->process_tui_live_outbound_transcript( 'skills', $paths, \%state ), 3, 'process_tui_live_outbound_transcript consumes new transcript rows for a paired chat' );
    is( $post_calls[0][0], 'sendChatAction', 'process_tui_live_outbound_transcript sends typing to Telegram for a TUI-originated turn' );
    is( $post_calls[1][0], 'sendMessage', 'process_tui_live_outbound_transcript sends the initial verbose trace to Telegram for a TUI-originated turn' );
    like( $post_calls[1][1]{text}, qr/Claude verbose/, 'process_tui_live_outbound_transcript starts the Telegram verbose trace for a TUI-originated turn' );
    is( $post_calls[2][0], 'editMessageText', 'process_tui_live_outbound_transcript edits the verbose trace with commentary progress' );
    is( $post_calls[-1][0], 'sendMessage', 'process_tui_live_outbound_transcript sends the final assistant reply back to Telegram' );
    is( $post_calls[-1][1]{text}, 'Tests tightened and rerun.', 'process_tui_live_outbound_transcript returns the final assistant reply text to Telegram' );
    is_deeply( \@typing_events, [ 'guard-start', 'guard-stop' ], 'process_tui_live_outbound_transcript keeps the typing guard active around the full TUI-originated Telegram delivery' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $ps = File::Spec->catfile( $bin_dir, 'ps' );
    _write(
        $ps,
        "#!/bin/sh\nprintf '  11 1 ? 1 helper --noop\\n  22 9 pts/77 3 claude --resume 019e-real-tty\\n'\n"
    );
    chmod 0755, $ps or die "Unable to chmod fake ps helper: $!";
    local $ENV{PATH} = $bin_dir;
    my $manager = new_manager(
        cwd  => $home,
        home => $home,
        tmux_panes_runner => sub {
            return [
                {
                    pane_id         => '%118',
                    tty             => '/dev/pts/77',
                    current_command => 'node',
                },
            ];
        },
    );
    is( $manager->discover_claude_session_tty('019e-real-tty'), 'pts/77', 'discover_claude_session_tty uses the real ps branch and skips unrelated or ttyless rows' );
    my @rows = $manager->claude_process_rows;
    is( $rows[1]{cmd}, 'claude --resume 019e-real-tty', 'claude_process_rows parses ps output through the default branch' );
    is( $rows[1]{etimes}, 3, 'claude_process_rows parses elapsed seconds through the default branch' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $bin_dir = File::Spec->catdir( $home, 'bin' );
    make_path($bin_dir);
    my $tmux = File::Spec->catfile( $bin_dir, 'tmux' );
    my $log = File::Spec->catfile( $home, 'tmux-send.log' );
    _write(
        $tmux,
        <<"EOF"
#!/bin/sh
if [ "\$1" = "list-panes" ]; then
  printf '%%118|/dev/pts/77|node\n'
  exit 0
fi
if [ "\$1" = "send-keys" ]; then
  printf '%s|' "\$@" >> "$log"
  printf '\n' >> "$log"
  exit 0
fi
exit 1
EOF
    );
    chmod 0755, $tmux or die "Unable to chmod fake tmux helper: $!";
    local $ENV{PATH} = $bin_dir;
    my $manager = new_manager( cwd => $home, home => $home );
    my @panes = $manager->tmux_pane_rows;
    is( $panes[0]{pane_id}, '%118', 'tmux_pane_rows uses the real tmux list-panes branch' );
    is( $manager->discover_tmux_pane_for_tty('pts/77'), '%118', 'discover_tmux_pane_for_tty matches a tty without a /dev prefix' );
    ok( !defined $manager->discover_tmux_pane_for_tty('pts/99'), 'discover_tmux_pane_for_tty returns undef when no tmux pane matches the tty' );
    ok( $manager->tmux_send_text_to_pane( '%118', 'Remember this code abc:foo' ), 'tmux_send_text_to_pane uses the real tmux send-keys branch' );
    my $send_log = do {
        open my $fh, '<', $log or die $!;
        local $/;
        <$fh>;
    };
    like( $send_log, qr/send-keys\|-t\|%118\|-l\|--\|Remember this code abc:foo\|/, 'tmux_send_text_to_pane sends literal text to the target pane' );
    like( $send_log, qr/send-keys\|-t\|%118\|C-j\|/, 'tmux_send_text_to_pane sends Ctrl-J to submit the injected text into the Claude TUI composer' );
}

{
    my $manager = new_manager(
        process_list_runner => sub {
            return [
                {
                    pid    => 100,
                    ppid   => 1,
                    tty    => 'pts/34',
                    etimes => 30_000,
                    cmd    => 'claude --resume 019e-prefer-newest',
                },
                {
                    pid    => 200,
                    ppid   => 99,
                    tty    => 'pts/0',
                    etimes => 10,
                    cmd    => 'claude --resume 019e-prefer-newest',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                { pane_id => '%118', tty => '/dev/pts/34', current_command => 'node' },
                { pane_id => '%77',  tty => '/dev/pts/0',  current_command => 'node' },
            ];
        },
    );
    is( $manager->discover_claude_session_tty('019e-prefer-newest'), 'pts/0', 'discover_claude_session_tty prefers the freshest matching claude --resume process' );
    is( $manager->resolve_claude_live_tmux_pane('019e-prefer-newest'), '%77', 'resolve_claude_live_tmux_pane maps the freshest matching claude --resume process to its tmux pane' );
}

{
    my $manager = new_manager(
        process_list_runner => sub {
            return [
                {
                    pid    => 200,
                    ppid   => 99,
                    tty    => 'pts/0',
                    etimes => 10,
                    cmd    => 'claude --resume 019e-prune-stale',
                },
                {
                    pid    => 150,
                    ppid   => 1,
                    tty    => 'pts/0',
                    etimes => 60,
                    cmd    => 'claude --resume 019e-prune-stale',
                },
                {
                    pid    => 140,
                    ppid   => 1,
                    tty    => 'pts/0',
                    etimes => 120,
                    cmd    => 'claude --resume 019e-prune-stale',
                },
                {
                    pid    => 300,
                    ppid   => 77,
                    tty    => 'pts/1',
                    etimes => 20,
                    cmd    => 'claude --resume 019e-prune-stale',
                },
                {
                    pid    => 250,
                    ppid   => 1,
                    tty    => 'pts/1',
                    etimes => 80,
                    cmd    => 'claude --resume 019e-prune-stale',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                { pane_id => '%77', tty => '/dev/pts/0', current_command => 'node' },
                { pane_id => '%88', tty => '/dev/pts/1', current_command => 'node' },
            ];
        },
    );
    is_deeply(
        [ map { $_->{pid} } $manager->stale_claude_resume_process_rows('019e-prune-stale') ],
        [ 150, 250, 140 ],
        'stale_claude_resume_process_rows returns only older orphaned claude --resume processes behind the freshest live pane owners',
    );
}

{
    my @signals;
    my %running = (
        150 => 1,
        250 => 1,
    );
    my $home = tempdir( CLEANUP => 1 );
    my $paths = {
        runtime_dir => File::Spec->catdir( $home, 'runtime' ),
        audit_file  => File::Spec->catfile( $home, 'runtime', 'audit.jsonl' ),
    };
    make_path( $paths->{runtime_dir} );
    _write( File::Spec->catfile( $paths->{runtime_dir}, 'audit.enabled' ), "1\n" );
    my $manager = new_manager(
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_AUDIT => 1,
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 200,
                    ppid   => 99,
                    tty    => 'pts/0',
                    etimes => 10,
                    cmd    => 'claude --resume 019e-prune-live',
                },
                {
                    pid    => 150,
                    ppid   => 1,
                    tty    => 'pts/0',
                    etimes => 60,
                    cmd    => 'claude --resume 019e-prune-live',
                },
                {
                    pid    => 300,
                    ppid   => 77,
                    tty    => 'pts/1',
                    etimes => 20,
                    cmd    => 'claude --resume 019e-prune-live',
                },
                {
                    pid    => 250,
                    ppid   => 1,
                    tty    => 'pts/1',
                    etimes => 80,
                    cmd    => 'claude --resume 019e-prune-live',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                { pane_id => '%77', tty => '/dev/pts/0', current_command => 'node' },
                { pane_id => '%88', tty => '/dev/pts/1', current_command => 'node' },
            ];
        },
        pid_check_runner => sub {
            my ($pid) = @_;
            return $running{$pid} ? 1 : 0;
        },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            delete $running{$pid};
            return 1;
        },
        sleep_runner => sub { return 1; },
    );
    is_deeply(
        [ $manager->prune_stale_claude_resume_processes( '019e-prune-live', $paths ) ],
        [ 150, 250 ],
        'prune_stale_claude_resume_processes terminates stale orphaned claude --resume processes and reports the pruned pids',
    );
    is_deeply(
        \@signals,
        [
            [ 'TERM', 150 ],
            [ 'TERM', 250 ],
        ],
        'prune_stale_claude_resume_processes tries TERM first for each stale claude --resume process',
    );
    my $audit = do {
        open my $fh, '<', $paths->{audit_file} or die $!;
        local $/;
        <$fh>;
    };
    like( $audit, qr/"pid":150.*"type":"claude\.resume\.pruned"|"type":"claude\.resume\.pruned".*"pid":150/s, 'prune_stale_claude_resume_processes records an audit event for the first pruned process' );
    like( $audit, qr/"pid":250.*"type":"claude\.resume\.pruned"|"type":"claude\.resume\.pruned".*"pid":250/s, 'prune_stale_claude_resume_processes records an audit event for the second pruned process' );
}

{
    my @signals;
    my %running = ( 150 => 1 );
    my $kill_seen = 0;
    my $sleep_after_kill = 0;
    my $home = tempdir( CLEANUP => 1 );
    my $paths = {
        runtime_dir => File::Spec->catdir( $home, 'runtime' ),
        audit_file  => File::Spec->catfile( $home, 'runtime', 'audit.jsonl' ),
    };
    make_path( $paths->{runtime_dir} );
    _write( File::Spec->catfile( $paths->{runtime_dir}, 'audit.enabled' ), "1\n" );
    my $manager = new_manager(
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_AUDIT => 1,
        },
        process_list_runner => sub {
            return [
                {
                    pid    => 200,
                    ppid   => 99,
                    tty    => 'pts/0',
                    etimes => 10,
                    cmd    => 'claude --resume 019e-prune-kill',
                },
                {
                    pid    => 150,
                    ppid   => 1,
                    tty    => 'pts/0',
                    etimes => 60,
                    cmd    => 'claude --resume 019e-prune-kill',
                },
            ];
        },
        tmux_panes_runner => sub {
            return [
                { pane_id => '%77', tty => '/dev/pts/0', current_command => 'node' },
            ];
        },
        pid_check_runner => sub {
            my ($pid) = @_;
            return $running{$pid} ? 1 : 0;
        },
        process_signal_runner => sub {
            my ( $signal, $pid ) = @_;
            push @signals, [ $signal, $pid ];
            $kill_seen = 1 if $signal eq 'KILL';
            return 1;
        },
        sleep_runner => sub {
            if ($kill_seen) {
                $sleep_after_kill++;
                delete $running{150} if $sleep_after_kill >= 1;
            }
            return 1;
        },
    );
    is_deeply(
        [ $manager->prune_stale_claude_resume_processes( '019e-prune-kill', $paths ) ],
        [ 150 ],
        'prune_stale_claude_resume_processes escalates to KILL when TERM does not clear a stale claude --resume process',
    );
    is_deeply(
        \@signals,
        [
            [ 'TERM', 150 ],
            [ 'KILL', 150 ],
        ],
        'prune_stale_claude_resume_processes escalates from TERM to KILL for a stubborn stale claude --resume process',
    );
}

{
    my $manager = new_manager;
    my $prompt = $manager->claude_live_pane_prompt(
        {
            text    => 'Check this image',
            caption => 'latest upload',
            photo   => { local_path => '/tmp/photo.png' },
            audio   => { title => 'tone' },
        }
    );
    like( $prompt, qr/\ACheck this image\n\[caption\] latest upload\n/s, 'claude_live_pane_prompt starts with the text and caption when both are present' );
    like( $prompt, qr/Any \*_local_path values below are already downloaded locally for this active Claude session\./, 'claude_live_pane_prompt includes the downloaded-local preface when media exists' );
    like( $prompt, qr/\[photo\] \/tmp\/photo\.png/, 'claude_live_pane_prompt includes media summary lines for downloaded files' );
    like( $prompt, qr/\[audio\] tone/, 'claude_live_pane_prompt includes non-file media summary lines too' );
}

{
    my $runtime = tempdir( CLEANUP => 1 );
    my $home = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-bootstrap-session';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write(
        $session_file,
        encode_json(
            {
                timestamp => '2026-05-22T18:31:01Z',
                type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => 'Bootstrap only' } ],
                },
            }
        ) . "\n",
    );
    my $manager = new_manager(
        cwd  => $runtime,
        home => $home,
        env  => { TELEGRAM_CLAUDE_SESSION_ID => 'skills' },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    _write( File::Spec->catfile( $runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 398296603 } ) );
    _write( File::Spec->catfile( $runtime_dir, 'claude.session' ), "$session_id\n" );
    my %state;
    my $paths = $manager->listener_paths_for_session('skills');
    is( $manager->process_tui_live_outbound_transcript( 'skills', $paths, \%state ), 0, 'process_tui_live_outbound_transcript primes the cursor and returns without replaying old transcript rows when no cursor exists yet' );
    is( $manager->read_text_file( $paths->{transcript_cursor_file} ), (-s $session_file) . "\n", 'process_tui_live_outbound_transcript stores the transcript EOF cursor on first bootstrap' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-outbound-multipoll';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write(
        $session_file,
        join(
            "\n",
            encode_json(
                {
                    timestamp => '2026-05-23T09:12:01Z',
                    type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => 'Please continue' } ],
                    },
                }
            ),
            encode_json(
                {
                    timestamp => '2026-05-23T09:12:02Z',
                    type      => 'assistant',
                    phase     => 'commentary',
                    message   => {
                        role    => 'assistant',
                        content => [ { type => 'text', text => 'Checking the current test state.' } ],
                    },
                }
            ),
            q{},
        ),
    );
    my @post_calls;
    my @typing_events;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => { TELEGRAM_CLAUDE_SESSION_ID => 'skills' },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            return {
                ok     => JSON::XS::true,
                result => {
                    message_id => 900 + scalar @post_calls,
                    chat       => { id => $params->{chat_id} },
                },
            };
        },
        typing_guard_runner => sub {
            my ( $summary, $self ) = @_;
            push @typing_events, 'guard-start';
            return sub {
                push @typing_events, 'guard-stop';
                return 1;
            };
        },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    _write( File::Spec->catfile( $runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 398296603 } ) );
    _write( File::Spec->catfile( $runtime_dir, 'claude.session' ), "$session_id\n" );
    _write( File::Spec->catfile( $runtime_dir, 'transcript.cursor' ), "0\n" );
    my %state;
    my $paths = $manager->listener_paths_for_session('skills');
    is( $manager->process_tui_live_outbound_transcript( 'skills', $paths, \%state ), 2, 'process_tui_live_outbound_transcript starts and keeps a TUI-originated turn active across the first transcript poll' );
    ok( $state{active}, 'process_tui_live_outbound_transcript leaves the active TUI mirror state open when no final answer has been seen yet' );
    is_deeply( \@typing_events, ['guard-start'], 'process_tui_live_outbound_transcript starts the typing guard on the first poll and does not stop it before a final answer exists' );
    _write(
        $session_file,
        join(
            "\n",
            encode_json(
                {
                    timestamp => '2026-05-23T09:12:01Z',
                    type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => 'Please continue' } ],
                    },
                }
            ),
            encode_json(
                {
                    timestamp => '2026-05-23T09:12:02Z',
                    type      => 'assistant',
                    phase     => 'commentary',
                    message   => {
                        role    => 'assistant',
                        content => [ { type => 'text', text => 'Checking the current test state.' } ],
                    },
                }
            ),
            encode_json(
                {
                    timestamp => '2026-05-23T09:12:03Z',
                    type      => 'assistant',
                    phase     => 'final_answer',
                    message   => {
                        role    => 'assistant',
                        content => [ { type => 'text', text => 'Tightened the checks and reran them.' } ],
                    },
                }
            ),
            q{},
        ),
    );
    is( $manager->process_tui_live_outbound_transcript( 'skills', $paths, \%state ), 1, 'process_tui_live_outbound_transcript consumes the later final assistant turn on the next transcript poll' );
    ok( !$state{active}, 'process_tui_live_outbound_transcript clears the active TUI mirror state after the final assistant turn is delivered' );
    is_deeply( \@typing_events, [ 'guard-start', 'guard-stop' ], 'process_tui_live_outbound_transcript keeps the typing guard alive across transcript polls until final delivery' );
    is( $post_calls[-1][0], 'sendMessage', 'process_tui_live_outbound_transcript still sends the final assistant reply after the multi-poll live TUI path' );
    is( $post_calls[-1][1]{text}, 'Tightened the checks and reran them.', 'process_tui_live_outbound_transcript returns the later final assistant reply text after the multi-poll live TUI path' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-outbound-on-error';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write(
        $session_file,
        join(
            "\n",
            encode_json(
                {
                    timestamp => '2026-05-22T18:31:01Z',
                    type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => 'Please continue' } ],
                    },
                }
            ),
            encode_json(
                {
                    timestamp => '2026-05-22T18:31:02Z',
                    type      => 'assistant',
                    phase     => 'final_answer',
                    message   => {
                        role    => 'assistant',
                        content => [ { type => 'text', text => 'Finished.' } ],
                    },
                }
            ),
            q{},
        ),
    );
    my @post_calls;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => { TELEGRAM_CLAUDE_SESSION_ID => 'skills' },
        post_runner => sub {
            my ( $method, $params ) = @_;
            push @post_calls, [ $method, $params ];
            die "Telegram POST failed for sendMessage: 500 Verbose kickoff rejected\n"
              if $method eq 'sendMessage' && ( $params->{text} || q{} ) =~ /Claude verbose/;
            return {
                ok     => JSON::XS::true,
                result => {
                    message_id => 800 + scalar @post_calls,
                    chat       => { id => $params->{chat_id} },
                },
            };
        },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    _write( File::Spec->catfile( $runtime_dir, 'pairing.json' ), encode_json( { paired_chat_id => 398296603 } ) );
    _write( File::Spec->catfile( $runtime_dir, 'claude.session' ), "$session_id\n" );
    _write( File::Spec->catfile( $runtime_dir, 'transcript.cursor' ), "0\n" );
    my %state;
    my @progress_errors;
    my $paths = $manager->listener_paths_for_session('skills');
    is( $manager->process_tui_live_outbound_transcript( 'skills', $paths, \%state, progress_errors => \@progress_errors ), 2, 'process_tui_live_outbound_transcript still consumes transcript rows when the initial verbose kickoff fails' );
    is( $post_calls[0][0], 'sendChatAction', 'process_tui_live_outbound_transcript still attempts typing before the reporter error path' );
    is( $post_calls[1][0], 'sendMessage', 'process_tui_live_outbound_transcript attempts the verbose kickoff message before the error callback path' );
    like( $progress_errors[0]{error}, qr/Verbose kickoff rejected/, 'process_tui_live_outbound_transcript captures the verbose kickoff failure through the on_error callback' );
    is( $post_calls[-1][1]{text}, 'Finished.', 'process_tui_live_outbound_transcript still delivers the final assistant reply after the verbose kickoff failure' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-pane-no-user';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write( $session_file, q{} );
    my $pauses = 0;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => { TELEGRAM_CLAUDE_SESSION_ID => 'skills' },
        tmux_send_runner => sub { return 1; },
        sleep_runner     => sub { $pauses++; return 1; },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    my $error = eval {
        $manager->run_claude_session_live_pane(
            $session_id,
            '%77',
            { text => 'Never shows up' },
        );
        return q{};
    };
    $error = $@ if !$error;
    like( $error, qr/never recorded the injected Telegram turn/, 'run_claude_session_live_pane fails fast when the live pane never records the injected Telegram turn' );
    is( $pauses, 14, 'run_claude_session_live_pane exits after the fast-fail user-detection window instead of waiting for the full timeout' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-pane-no-final';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    _write( $session_file, q{} );
    my $pauses = 0;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => { TELEGRAM_CLAUDE_SESSION_ID => 'skills' },
        tmux_send_runner => sub {
            _write(
                $session_file,
                join(
                    "\n",
                    encode_json(
                        {
                            timestamp => '2026-05-22T18:31:01Z',
                            type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => 'No final answer yet' } ],
                            },
                        }
                    ),
                    q{},
                )
            );
            return 1;
        },
        sleep_runner     => sub { $pauses++; return 1; },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    my $error = eval {
        $manager->run_claude_session_live_pane(
            $session_id,
            '%77',
            {
                text       => 'No final answer yet',
                chat       => { id => 398296603 },
                message_id => 95,
            },
        );
        return q{};
    };
    $error = $@ if !$error;
    like( $error, qr/Timed out waiting for the live Claude pane to finish the Telegram turn/, 'run_claude_session_live_pane times out when the injected user turn appears but no final assistant answer follows' );
    is( $pauses, 600, 'run_claude_session_live_pane waits through the full live-pane window when the user turn appears but no final assistant answer arrives' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-pane-progress-error';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    my $prompt = "Check progress callback failure";
    _write( $session_file, q{} );
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => {
            TELEGRAM_CLAUDE_SESSION_ID => 'skills',
            TELEGRAM_CLAUDE_AUDIT      => '1',
        },
        tmux_send_runner => sub {
            _write(
                $session_file,
                join(
                    "\n",
                    encode_json(
                        {
                            timestamp => '2026-05-22T18:31:01Z',
                            type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => $prompt } ],
                            },
                        }
                    ),
                    encode_json(
                        {
                            timestamp => '2026-05-22T18:31:02Z',
                            type      => 'assistant',
                    phase     => 'commentary',
                    message   => {
                        role    => 'assistant',
                        content => [ { type => 'text', text => 'This commentary will fail' } ],
                            },
                        }
                    ),
                    encode_json(
                        {
                            timestamp => '2026-05-22T18:31:03Z',
                            type      => 'assistant',
                    phase     => 'final_answer',
                    message   => {
                        role    => 'assistant',
                        content => [ { type => 'text', text => 'Still finished.' } ],
                            },
                        }
                    ),
                    q{},
                ),
            );
            return 1;
        },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    my $reply = $manager->run_claude_session_live_pane(
        $session_id,
        '%118',
        { text => $prompt },
        on_progress => sub { die "progress callback blew up\n" },
    );
    is( $reply, 'Still finished.', 'run_claude_session_live_pane still returns the final answer after a progress callback failure' );
    my $audit = $manager->read_text_file( $manager->listener_paths->{audit_file} );
    like( $audit, qr/claude\.live_pane\.progress_callback_failed/, 'run_claude_session_live_pane audits the progress callback failure' );
    like( $audit, qr/progress callback blew up/, 'run_claude_session_live_pane preserves the progress callback failure detail' );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $cwd = tempdir( CLEANUP => 1 );
    my $session_id = '019e-live-pane-timeout';
    my $session_dir = File::Spec->catdir( $home, '.claude', 'projects', '-encoded-project' );
    make_path($session_dir);
    my $session_file = File::Spec->catfile( $session_dir, "$session_id.jsonl" );
    my $prompt = "Wait forever";
    _write( $session_file, q{} );
    my $pauses = 0;
    my $manager = new_manager(
        cwd  => $cwd,
        home => $home,
        env  => { TELEGRAM_CLAUDE_SESSION_ID => 'skills' },
        tmux_send_runner => sub {
            _write(
                $session_file,
                encode_json(
                    {
                        timestamp => '2026-05-22T18:31:01Z',
                        type      => 'user',
            message   => {
                role    => 'user',
                content => [ { type => 'text', text => $prompt } ],
                        },
                    }
                ) . "\n",
            );
            return 1;
        },
        sleep_runner => sub { $pauses++; return 1; },
    );
    my $runtime_dir = $manager->listener_paths_for_session('skills')->{runtime_dir};
    make_path($runtime_dir);
    my $error = eval {
        $manager->run_claude_session_live_pane(
            $session_id,
            '%118',
            { text => $prompt },
        );
        return q{};
    };
    $error = $@ if !$error;
    like( $error, qr/Timed out waiting for the live Claude pane to finish the Telegram turn/, 'run_claude_session_live_pane fails explicitly when no final answer arrives from the live transcript' );
    is( $pauses, 600, 'run_claude_session_live_pane executes the live-pane wait loop until timeout when no final answer arrives' );
}

{
    my $manager = new_manager;
    ok(
        $manager->claude_live_pane_user_event_matches_prompt(
            { text => 'Test', caption => q{} },
            'Test',
            "  Test  \n",
        ),
        'claude_live_pane_user_event_matches_prompt tolerates normalized whitespace differences',
    );
    ok(
        $manager->claude_live_pane_user_event_matches_prompt(
            { text => 'Test', caption => q{} },
            'Test',
            "[Telegram chat 398296603 message 2355]\nTest",
        ),
        'claude_live_pane_user_event_matches_prompt accepts transcript rows that wrap the Telegram text',
    );
    ok(
        $manager->claude_live_pane_user_event_matches_prompt(
            { text => q{}, caption => 'Picture note' },
            "[caption] Picture note",
            "Some transcript preface\n[caption] Picture note",
        ),
        'claude_live_pane_user_event_matches_prompt accepts caption matches when the text body is empty',
    );
    ok(
        !$manager->claude_live_pane_user_event_matches_prompt(
            { text => 'Test', caption => 'Picture note' },
            "Test\n[caption] Picture note",
            'Completely unrelated transcript row',
        ),
        'claude_live_pane_user_event_matches_prompt rejects unrelated transcript rows',
    );
}

sub _write {
    my ( $file, $content ) = @_;
    open my $fh, '>', $file or die "Unable to write $file: $!";
    print {$fh} $content;
    close $fh or die "Unable to close $file: $!";
}

done_testing;
