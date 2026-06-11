package Telegram::Claude::Manager;

use strict;
use warnings;

use Cwd qw(getcwd);
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use HTTP::Request::Common qw(GET POST);
use IO::Select;
use IPC::Open3 qw(open3);
use JSON::XS qw(decode_json encode_json);
use LWP::UserAgent;
use Digest::SHA qw(sha1_hex);
use MIME::Base64 qw(encode_base64);
use Symbol qw(gensym);
use URI;

sub new {
    my ( $class, %args ) = @_;
    my $cwd = $args{cwd} || getcwd();
    my $home = defined $args{home} ? $args{home} : $ENV{HOME};
    my $skill_root = defined $args{skill_root} ? $args{skill_root} : $class->_default_skill_root;
    my $self = bless {
        cwd                  => $cwd,
        home                 => $home,
        os                   => defined $args{os} ? $args{os} : $^O,
        skill_root           => $skill_root,
        stdout_fh            => $args{stdout_fh} || \*STDOUT,
        stderr_fh            => $args{stderr_fh} || \*STDERR,
        env                  => {},
        get_runner           => $args{get_runner},
        post_runner          => $args{post_runner},
        download_runner      => $args{download_runner},
        listener_start_runner => $args{listener_start_runner},
        listener_start_pid   => $args{listener_start_pid},
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
        }, $class;
    $self->{env} = $args{env} || $self->_merged_env;
    $self->{ua} = $args{ua} || $self->_build_ua;
    return $self;
}

sub main_install          { return shift->_run_main( 'install',          @_ ) }
sub main_get_me           { return shift->_run_main( 'get_me',           @_ ) }
sub main_updates          { return shift->_run_main( 'updates',          @_ ) }
sub main_download         { return shift->_run_main( 'download',         @_ ) }
sub main_pair            { return shift->_run_main( 'pair',            @_ ) }
sub main_reply            { return shift->_run_main( 'reply',            @_ ) }
sub main_send_photo       { return shift->_run_main( 'send_photo',       @_ ) }
sub main_send_audio       { return shift->_run_main( 'send_audio',       @_ ) }
sub main_send_document    { return shift->_run_main( 'send_document',    @_ ) }
sub main_auto_reply_start { return shift->_run_main( 'auto_reply_start', @_ ) }
sub main_check_message    { return shift->_run_main( 'check_messages',   @_ ) }
sub main_start            { return shift->_run_main( 'start',            @_ ) }
sub main_stop             { return shift->_run_main( 'stop',             @_ ) }
sub main_e2e              { return shift->_run_main( 'e2e',              @_ ) }

sub _run_main {
    my ( $class, $mode, @argv ) = @_;
    my $self = ref($class) ? $class : $class->new;
    my $code = eval {
        if ( $mode eq 'start' && @argv && ( $argv[0] eq '--version' || $argv[0] eq '-V' || $argv[0] eq 'version' ) ) {
            print { $self->{stdout_fh} } $self->real_claude_version_output;
            return 0;
        }
        my $method = "execute_$mode";
        my $result = $self->$method(@argv);
        print { $self->{stdout_fh} } $self->encode_pretty_json($result) . "\n";
        return 0;
    };
    if ( my $error = $@ ) {
        chomp $error;
        print { $self->{stderr_fh} } "$error\n";
        return 2;
    }
    return $code;
}

sub execute_install {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.install <TELEGRAM_BOT_TOKEN>\n" if @argv > 1;
    my $token = $self->resolve_token( $argv[0] );
    my @targets = $self->plugin_targets;
    my @installed;
    for my $target (@targets) {
        push @installed, $self->scaffold_plugin(
            plugin_root      => $target->{plugin_root},
            marketplace_path => $target->{marketplace_path},
            token            => $token,
        );
    }
    my $claude_wrapper = $self->install_claude_launchers;
    return {
        mode      => 'install',
        plugin    => 'telegram-claude',
        installed => \@installed,
        claude_wrapper => $claude_wrapper,
    };
}

sub auto_setup {
    my ($self) = @_;
    return { mode => 'auto_setup', claude_wrapper => $self->install_claude_launchers };
}

sub execute_start {
    my ( $self, @argv ) = @_;
    my $audit_requested = scalar grep { defined $_ && $_ eq '--audit' } @argv;
    $audit_requested = $audit_requested ? 1 : 0;
    @argv = grep { !defined $_ || $_ ne '--audit' } @argv;
    my $cmd = defined $argv[0] ? $argv[0] : q{};

    if ( $cmd eq '--version' || $cmd eq '-V' || $cmd eq 'version' ) {
        return {
            mode    => 'start',
            action  => 'version',
            version => $self->env_value('VERSION') || '0.00',
        };
    }

    my $config_path = $self->claude_config_path;
    my $config = $self->read_claude_config($config_path);
    my $ticket = $self->workspace_session_id;

    if ( $cmd eq 'add' ) {
        my $claude_session_ref = defined $argv[1] ? $argv[1] : $ticket;
        die "Missing ticket ref\n" if !defined $ticket || $ticket eq q{} || !defined $claude_session_ref || $claude_session_ref eq q{};
        $config->{$ticket} = $claude_session_ref;
        $config->{_last_action} = "Add $ticket";
        $config->{_last_update} = $self->now_string;
        $self->write_claude_config( $config_path, $config );
        return {
            mode         => 'start',
            action       => 'add',
            ticket       => $ticket,
            claude_session => $claude_session_ref,
        };
    }

    if ( $cmd eq 'remove' ) {
        die "Missing ticket ref\n" if !defined $ticket || $ticket eq q{};
        my $claude_session_ref = $config->{$ticket}
          or die "Claude Session Not Found\n";
        die "Missing ticket ref\n" if !$claude_session_ref;
        delete $config->{$ticket};
        delete $config->{$claude_session_ref};
        $config->{_last_action} = "Remove $ticket";
        $config->{_last_update} = $self->now_string;
        $self->write_claude_config( $config_path, $config );
        return {
            mode         => 'start',
            action       => 'remove',
            ticket       => $ticket,
            claude_session => $claude_session_ref,
        };
    }

    my $plan = $self->claude_start_plan( $config, @argv );
    my $audit_session_id = defined $plan->{collector_session_id} && $plan->{collector_session_id} ne q{}
      ? $plan->{collector_session_id}
      : $self->workspace_session_id;
    $self->set_listener_audit_enabled( $audit_session_id, $audit_requested )
      if defined $audit_session_id && $audit_session_id ne q{};
    return $plan if $self->env_value('TELEGRAM_CLAUDE_START_CAPTURE');

    if ( $plan->{start_collector} ) {
        $self->ensure_startup_collector($plan);
        $self->recycle_check_message_session( $plan->{collector_session_id} );
        $self->restart_startup_collector($plan);
    }

    if ( defined $plan->{collector_session_id} && $plan->{collector_session_id} ne q{} ) {
        $ENV{CLAUDE_SESSION_ID} = $plan->{collector_session_id};
        $ENV{TELEGRAM_CLAUDE_SESSION_ID} = $plan->{collector_session_id};
    }

    my @claude_args = @{ $plan->{claude_args} };
    unshift @claude_args, '--dangerously-skip-permissions'
      if !grep { defined $_ && $_ eq '--dangerously-skip-permissions' } @claude_args;
    if ( my $ollama_model = $self->explicit_start_ollama_model ) {
        @claude_args = $self->inject_ollama_claude_args( $ollama_model, @claude_args );
    }

    $ENV{TELEGRAM_CLAUDE_START_ACTIVE} = 1;
    exec { $plan->{real_claude_bin} } $plan->{real_claude_bin}, @claude_args
      or die "Unable to exec $plan->{real_claude_bin}: $!";
}

sub execute_stop {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.stop\n" if @argv;
    my $session_id = $self->workspace_session_id;
    my $collector_name = $self->collector_name_for_session($session_id);
    my $stop_result = $self->stop_startup_collector($session_id);
    my $recycled_worker = $self->recycle_check_message_session($session_id) ? JSON::XS::true : JSON::XS::false;
    return {
        mode            => 'stop',
        session_id      => $session_id,
        collector_name  => $collector_name,
        recycled_worker => $recycled_worker,
        stop_result     => $stop_result,
    };
}

sub execute_e2e {
    my ( $self, @argv ) = @_;
    my $action = defined $argv[0] && $argv[0] ne q{} ? $argv[0] : 'status';
    die "Usage: dashboard telegram-claude.e2e [start|stop|status]\n"
      if @argv > 1 || $action !~ /\A(?:start|stop|status)\z/;

    if ( $action eq 'start' ) {
        if ( $self->e2e_stack_running ) {
            return {
                %{ $self->e2e_metadata },
                mode   => 'e2e',
                action => 'start',
                status => 'already-running',
            };
        }

        $self->write_e2e_env_file;
        $self->run_e2e_compose_command('build');
        $self->run_e2e_compose_command('down');
        $self->run_e2e_compose_command( 'up', '-d' );
        $self->write_text_file(
            $self->e2e_state_file,
            $self->encode_pretty_json(
                {
                    project_name   => $self->e2e_project_name,
                    workspace_path => $self->{cwd},
                    created_at     => $self->now_string,
                }
            ),
        );
        return {
            %{ $self->e2e_metadata },
            mode   => 'e2e',
            action => 'start',
            status => 'started',
        };
    }

    if ( $action eq 'stop' ) {
        if ( -f $self->e2e_env_file ) {
            $self->run_e2e_compose_command('down');
        }
        unlink $self->e2e_state_file if -f $self->e2e_state_file;
        unlink $self->e2e_env_file   if -f $self->e2e_env_file;
        return {
            %{ $self->e2e_metadata },
            mode   => 'e2e',
            action => 'stop',
            status => 'stopped',
        };
    }

    my $status = $self->e2e_stack_running ? 'running' : 'not-running';
    return {
        %{ $self->e2e_metadata },
        mode   => 'e2e',
        action => 'status',
        status => $status,
    };
}

sub execute_get_me {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.get-me\n" if @argv;
    return $self->telegram_get('getMe')->{result};
}

sub execute_updates {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.updates [OFFSET] [LIMIT] [TIMEOUT]\n" if @argv > 3;
    my $result = $self->telegram_get(
        'getUpdates',
        {
            ( defined $argv[0] ? ( offset => $argv[0] ) : () ),
            ( defined $argv[1] ? ( limit  => $argv[1] ) : () ),
            ( defined $argv[2] ? ( timeout => $argv[2] ) : () ),
        }
    );
    my @updates = map { $self->summarise_update($_) } @{ $result->{result} || [] };
    return {
        count       => scalar @updates,
        updates     => \@updates,
        next_offset => @updates ? $updates[-1]{update_id} + 1 : undef,
    };
}

sub execute_download {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.download <FILE_ID> [TARGET_DIR] [FILENAME]\n" if !@argv || @argv > 3;
    my ( $file_id, $target_dir, $filename ) = @argv;
    my $file = $self->telegram_get( 'getFile', { file_id => $file_id } )->{result};
    my $bytes = $self->telegram_download( $file->{file_path} );
    my $dir = $target_dir || File::Spec->catdir( $self->{cwd}, 'downloads' );
    make_path($dir) if !-d $dir;
    my $name = $filename || $self->basename( $file->{file_path} );
    my $path = File::Spec->catfile( $dir, $name );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    binmode $fh;
    print {$fh} $bytes;
    close $fh or die "Unable to close $path: $!";
    return {
        file_id            => $file_id,
        telegram_file_path => $file->{file_path},
        saved_to           => $path,
        bytes              => length $bytes,
    };
}

sub execute_reply {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.reply <CHAT_ID> <TEXT>\n" if @argv < 2;
    my $chat_id = shift @argv;
    my $text = join q{ }, @argv;
    return $self->telegram_post( 'sendMessage', { chat_id => $chat_id, text => $text } )->{result};
}

sub execute_pair {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.pair <HEX_CODE>|--clear-unknown-devices\n" if @argv != 1;
    my $session_id = $self->workspace_session_id;
    $self->ensure_listener_runtime_migrated($session_id);
    if ( defined $argv[0] && $argv[0] eq '--clear-unknown-devices' ) {
        my $paths = $self->listener_paths_for_session($session_id);
        my $shared_paths = $self->listener_shared_paths_for_session($session_id);
        my $state = $self->read_listener_pairing_state($paths);
        my $cleared_pending = delete $state->{pending_chat_id};
        delete $state->{pairing_code};
        delete $state->{challenge_sent_at};
        my $cleared_paired = delete $state->{paired_chat_id};
        delete $state->{paired_at};
        $self->write_listener_pairing_state( $paths, $state );
        $self->write_listener_pairing_claim(
            $shared_paths,
            {
                session_id => $session_id,
                claimed_at => $self->now_string,
            },
        );
        return {
            mode            => 'pair',
            action          => 'clear-unknown-devices',
            session_id      => $session_id,
            cleared_pending => defined $cleared_pending ? JSON::XS::true : JSON::XS::false,
            cleared_paired  => defined $cleared_paired ? JSON::XS::true : JSON::XS::false,
        };
    }
    my $provided_code = lc( $argv[0] // q{} );
    die "Pair code is required\n" if $provided_code eq q{};
    die "Pair code must be lowercase hexadecimal\n" if $provided_code !~ /\A[0-9a-f]+\z/;
    my $paths = $self->listener_paths_for_session($session_id);
    my $state = $self->read_listener_pairing_state($paths);
    die "No pending Telegram pairing challenge for this session\n"
      if !defined $state->{pending_chat_id} || !defined $state->{pairing_code} || $state->{pairing_code} eq q{};
    die "Pair code does not match the current pending Telegram challenge\n"
      if $provided_code ne lc( $state->{pairing_code} );
    $state->{paired_chat_id} = $state->{pending_chat_id};
    $state->{paired_at} = $self->now_string;
    delete @{$state}{qw(pending_chat_id challenge_sent_at pairing_code)};
    $self->write_listener_pairing_state( $paths, $state );
    $self->enforce_unique_listener_pairing( $self->listener_session_id, $paths );
    return {
        mode           => 'pair',
        session_id     => $self->listener_session_id,
        paired_chat_id => $state->{paired_chat_id},
        paired_at      => $state->{paired_at},
    };
}

sub execute_send_photo {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.send-photo <CHAT_ID> <PHOTO_PATH> [CAPTION]\n" if @argv < 2;
    my $chat_id = shift @argv;
    my $photo_path = shift @argv;
    my $caption = join q{ }, @argv;
    die "Photo path does not exist: $photo_path\n" if !-f $photo_path;
    return $self->telegram_post_file(
        'sendPhoto',
        { chat_id => $chat_id, caption => $caption },
        { photo   => $photo_path },
    )->{result};
}

sub execute_send_audio {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.send-audio <CHAT_ID> <AUDIO_PATH> [CAPTION]\n" if @argv < 2;
    my $chat_id = shift @argv;
    my $audio_path = shift @argv;
    my $caption = join q{ }, @argv;
    die "Audio path does not exist: $audio_path\n" if !-f $audio_path;
    return $self->telegram_post_file(
        'sendAudio',
        { chat_id => $chat_id, caption => $caption },
        { audio   => $audio_path },
    )->{result};
}

sub execute_send_document {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.send-document <CHAT_ID> <DOCUMENT_PATH> [CAPTION]\n" if @argv < 2;
    my $chat_id = shift @argv;
    my $document_path = shift @argv;
    my $caption = join q{ }, @argv;
    die "Document path does not exist: $document_path\n" if !-f $document_path;
    return $self->telegram_post_file(
        'sendDocument',
        { chat_id => $chat_id, caption => $caption },
        { document => $document_path },
    )->{result};
}

sub execute_auto_reply_start {
    my ( $self, @argv ) = @_;
    my $reply_text = @argv
      ? join( q{ }, @argv )
      : 'Talbot Telegram bridge is live. Send text, photos, or files here and ask Claude to poll and reply.';
    my $result = $self->telegram_get( 'getUpdates', { limit => 20, timeout => 0 } );
    my @replied;
    my @updates = @{ $result->{result} || [] };
    for my $update (@updates) {
        my $message = $update->{message} || $update->{edited_message} || {};
        my $text = defined $message->{text} ? $message->{text} : q{};
        next if $text ne '/start';
        my $chat_id = $message->{chat}{id};
        next if !defined $chat_id;
        my $sent = $self->telegram_post(
            'sendMessage',
            {
                chat_id             => $chat_id,
                text                => $reply_text,
                reply_to_message_id => $message->{message_id},
            }
        )->{result};
        push @replied, {
            update_id  => $update->{update_id},
            chat_id    => $chat_id,
            message_id => $sent->{message_id},
        };
    }
    if (@updates) {
        $self->telegram_get( 'getUpdates', { offset => $updates[-1]{update_id} + 1 } );
    }
    return {
        checked     => scalar @updates,
        replied     => \@replied,
        next_offset => @updates ? $updates[-1]{update_id} + 1 : undef,
    };
}

sub execute_listen {
    my ( $self, @argv ) = @_;
    return $self->execute_check_messages(@argv);
}

sub execute_check_messages {
    my ( $self, @argv ) = @_;
    die "Usage: dashboard telegram-claude.check-message [SESSION_ID] [MAX_CYCLES] [POLL_TIMEOUT] [REPLY_TEXT]\n" if @argv > 4;
    my $session_id;
    if ( @argv && $argv[0] !~ /\A\d+\z/ ) {
        $session_id = shift @argv;
    }
    my $max_cycles;
    my $poll_timeout = 30;
    if ( @argv && $argv[0] =~ /\A\d+\z/ ) {
        $max_cycles = shift @argv;
        $max_cycles = undef if defined $max_cycles && $max_cycles == 0;
    }
    if ( @argv && $argv[0] =~ /\A\d+\z/ ) {
        $poll_timeout = shift @argv;
    }
    my $reply_text = @argv
      ? join( q{ }, @argv )
      : undef;

    $session_id = $self->listener_session_id if !defined $session_id || $session_id eq q{};
    $self->{env}{TELEGRAM_CLAUDE_SESSION_ID} = $session_id;
    $ENV{TELEGRAM_CLAUDE_SESSION_ID} = $session_id;
    $self->ensure_listener_runtime_migrated($session_id);
    my $paths = $self->listener_paths_for_session($session_id);
    my $shared_paths = $self->listener_shared_paths_for_session($session_id);
    make_path( $paths->{runtime_dir} ) if !-d $paths->{runtime_dir};
    my $audit_enabled = $self->listener_audit_enabled($paths);
    my $guard = $self->begin_check_message_session($session_id, $paths);
    return {
        mode        => 'check_message',
        session_id  => $session_id,
        skipped     => 1,
        running_pid => $guard->{running_pid},
        pid_file    => $paths->{pid_file},
    } if $guard->{already_running};
    my @unpaired_sessions = $self->enforce_unique_listener_pairing( $session_id, $paths );
    my $target_session_id = $self->resolve_claude_reply_session_id;
    my @pruned_live_resume_pids = $self->prune_stale_claude_resume_processes( $target_session_id, $paths );
    my $offset = $self->read_listener_offset( $shared_paths->{offset_file} );
    my $recovered_offset = $self->recover_listener_offset_from_inbox( $shared_paths->{inbox_file} );
    if ( defined $recovered_offset ) {
        if ( !defined $offset || $recovered_offset > $offset ) {
            $offset = $recovered_offset;
            $self->write_listener_offset( $shared_paths->{offset_file}, $offset );
        }
    }
    my $prime_latest = ( $self->env_value('TELEGRAM_CLAUDE_LISTENER_PRIME_LATEST') || q{} ) =~ /\A(?:1|true|yes|on)\z/i ? 1 : 0;
    if ( !defined $offset && $prime_latest ) {
        my $prime_offset;
        while (1) {
            my %prime_params = (
                limit   => 100,
                timeout => 0,
            );
            $prime_params{offset} = $prime_offset if defined $prime_offset;
            my $prime_result = $self->telegram_get( 'getUpdates', \%prime_params );
            my @prime_updates = @{ $prime_result->{result} || [] };
            last if !@prime_updates;
            $prime_offset = $prime_updates[-1]{update_id} + 1;
            last if @prime_updates < 100;
        }
        if ( defined $prime_offset ) {
            $offset = $prime_offset;
            $self->write_listener_offset( $shared_paths->{offset_file}, $offset );
        }
    }
    my $cycles = 0;
    my $processed = 0;
    my $replied = 0;
    my @reply_errors;
    my @typing_errors;
    my @get_errors;
    my @progress_errors;
    my $live_outbound_state = {};

    $self->append_listener_audit_event(
        $paths,
        'check-message.started',
        {
            session_id              => $session_id,
            target_session_id       => $target_session_id,
            max_cycles              => $max_cycles,
            poll_timeout            => $poll_timeout,
            reply_mode              => $self->listener_reply_mode_for_update($reply_text),
            audit_enabled           => $audit_enabled ? JSON::XS::true : JSON::XS::false,
            pruned_live_resume_pids => \@pruned_live_resume_pids,
            unpaired_sessions       => \@unpaired_sessions,
        },
    );

    while (1) {
        $self->process_tui_live_outbound_transcript(
            $session_id,
            $paths,
            $live_outbound_state,
            progress_errors => \@progress_errors,
            reply_errors    => \@reply_errors,
        );
        my $poll_guard = $self->begin_listener_global_poll_session( $session_id, $shared_paths );
        if ( !$poll_guard->{poll_owner} ) {
            $cycles++;
            last if defined $max_cycles && $cycles >= $max_cycles;
            $self->listener_pause_seconds(1);
            next;
        }
        my %params = (
            limit   => 20,
            timeout => $poll_timeout,
        );
        $params{offset} = $offset if defined $offset;
        my $result = eval { $self->telegram_get( 'getUpdates', \%params ) };
        if ( my $error = $@ ) {
            chomp $error;
            push @get_errors, {
                cycle => $cycles,
                error => $error,
            };
            $self->append_listener_audit_event(
                $paths,
                'getUpdates.failed',
                {
                    cycle => $cycles,
                    error => $error,
                },
            );
            $cycles++;
            last if defined $max_cycles && $cycles >= $max_cycles;
            $self->listener_pause_seconds(1);
            next;
        }
        my @updates = @{ $result->{result} || [] };
        for my $update (@updates) {
            my $update_id = $update->{update_id};
            next if defined $offset && defined $update_id && $update_id < $offset;
            my $summary = $self->summarise_update($update);
            my ( $target_listener_session_id, $target_paths ) = $self->listener_target_for_summary( $summary, $session_id );
            next if defined $update_id && $self->inbox_contains_update_id( $target_paths->{inbox_file}, $update_id );
            $self->append_inbox_entry( $shared_paths->{inbox_file}, $summary );
            $self->append_inbox_entry( $target_paths->{inbox_file}, $summary );
            $self->append_listener_audit_event(
                $target_paths,
                'update.received',
                {
                    update_id  => $summary->{update_id},
                    message_id => $summary->{message_id},
                    chat_id    => defined $summary->{chat} ? $summary->{chat}{id} : undef,
                    has_text   => defined $summary->{text} && $summary->{text} ne q{} ? JSON::XS::true : JSON::XS::false,
                    has_media  => $self->summary_has_media($summary) ? JSON::XS::true : JSON::XS::false,
                    routed_by  => $session_id,
                },
            );
            $processed++;
            my $outcome = $self->process_listener_update(
                session_id      => $target_listener_session_id,
                paths           => $target_paths,
                summary         => $summary,
                reply_text      => $reply_text,
                typing_errors   => \@typing_errors,
                progress_errors => \@progress_errors,
                reply_errors    => \@reply_errors,
            );
            $replied++ if $outcome->{replied};
        }
        if (@updates) {
            $offset = $updates[-1]{update_id} + 1;
            $self->write_listener_offset( $shared_paths->{offset_file}, $offset );
        }
        $cycles++;
        $self->process_tui_live_outbound_transcript(
            $session_id,
            $paths,
            $live_outbound_state,
        progress_errors => \@progress_errors,
        reply_errors    => \@reply_errors,
    );
        last if defined $max_cycles && $cycles >= $max_cycles;
    }

    return {
        mode            => 'check_message',
        session_id      => $session_id,
        target_session_id => $target_session_id,
        cycles          => $cycles,
        processed       => $processed,
        replied         => $replied,
        get_errors      => \@get_errors,
        typing_errors   => \@typing_errors,
        progress_errors => \@progress_errors,
        reply_errors    => \@reply_errors,
        next_offset     => $offset,
        offset_file     => $shared_paths->{offset_file},
        inbox_file      => $shared_paths->{inbox_file},
        pid_file        => $paths->{pid_file},
        audit_file      => $paths->{audit_file},
        pruned_live_resume_pids => \@pruned_live_resume_pids,
        unpaired_sessions => \@unpaired_sessions,
    };
}

sub process_listener_update {
    my ( $self, %args ) = @_;
    my $session_id = $args{session_id};
    my $paths = $args{paths};
    my $summary = $args{summary};
    my $reply_text = $args{reply_text};
    my $typing_errors = $args{typing_errors} || [];
    my $progress_errors = $args{progress_errors} || [];
    my $reply_errors = $args{reply_errors} || [];
    my $message_id = $summary->{message_id};
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : undef;
    my $replied = 0;

    $self->with_listener_session_context(
        $session_id,
        sub {
            my $pairing_action = $self->listener_pairing_action( $summary, $paths );
            if ( !$pairing_action->{allow} ) {
                if ( defined $chat_id && $pairing_action->{reply_message} ) {
                    my $sent = eval {
                        $self->dispatch_listener_reply(
                            chat_id             => $chat_id,
                            reply_to_message_id => $message_id,
                            reply_message       => $pairing_action->{reply_message},
                        );
                        return 1;
                    };
                    if ( my $error = $@ ) {
                        chomp $error;
                        push @{$reply_errors}, {
                            update_id  => $summary->{update_id},
                            chat_id    => $chat_id,
                            message_id => $message_id,
                            error      => $error,
                        };
                        $self->append_listener_audit_event(
                            $paths,
                            'reply.failed',
                            {
                                update_id  => $summary->{update_id},
                                message_id => $message_id,
                                chat_id    => $chat_id,
                                error      => $error,
                            },
                        );
                    }
                    elsif ($sent) {
                        $replied++;
                    }
                }
                return;
            }
            my $slash_reply = $self->listener_slash_command_reply( $summary, $paths );
            if ( defined $chat_id && defined $slash_reply ) {
                my $sent = eval {
                    $self->dispatch_listener_reply( chat_id => $chat_id, reply_to_message_id => $message_id, reply_message => $slash_reply );
                    return 1;
                };
                if ( my $error = $@ ) {
                    chomp $error;
                    push @{$reply_errors}, {
                        update_id  => $summary->{update_id},
                        chat_id    => $chat_id,
                        message_id => $message_id,
                        error      => $error,
                    };
                    $self->append_listener_audit_event(
                        $paths,
                        'slash_command.reply_failed',
                        {
                            update_id  => $summary->{update_id},
                            message_id => $message_id,
                            chat_id    => $chat_id,
                            command    => $self->listener_slash_command_name($summary),
                            error      => $error,
                        },
                    );
                }
                elsif ($sent) {
                    $replied++;
                    $self->append_listener_audit_event(
                        $paths,
                        'slash_command.replied',
                        {
                            update_id  => $summary->{update_id},
                            message_id => $message_id,
                            chat_id    => $chat_id,
                            command    => $self->listener_slash_command_name($summary),
                        },
                    );
                }
                return;
            }
            my $reply_mode = $self->listener_reply_mode_for_update($reply_text);
            $summary = $self->hydrate_summary_media_paths($summary)
              if $reply_mode eq 'claude-session';
            return if !defined $chat_id || !$self->update_needs_listener_reply($summary);
            my $sent = eval {
                my $runner = sub {
                    my $reporter = ( $reply_mode eq 'claude-session' && $self->listener_should_stream_progress($summary) )
                      ? $self->start_listener_verbose_reporter(
                            $summary,
                            on_error => sub {
                                my ($error) = @_;
                                push @{$progress_errors}, {
                                    update_id  => $summary->{update_id},
                                    chat_id    => $chat_id,
                                    message_id => $message_id,
                                    error      => $error,
                                };
                                $self->append_listener_audit_event(
                                    $paths,
                                    'progress.reporter.failed',
                                    {
                                        update_id  => $summary->{update_id},
                                        message_id => $message_id,
                                        chat_id    => $chat_id,
                                        error      => $error,
                                    },
                                );
                                return 1;
                            },
                        )
                      : undef;
                    eval { $reporter->{emit}->('Resuming active Claude session') } if $reporter;
                    my $reply_message = $self->listener_reply_message_for_update(
                        $summary,
                        $reply_text,
                        $reply_mode,
                        (
                            $reporter
                            ? (
                                on_progress => sub {
                                    my ($line) = @_;
                                    my $ok = eval { $reporter->{emit}->($line) };
                                    if ($@) {
                                        my $error = $@;
                                        chomp $error;
                                        $error ||= 'Unknown Telegram verbose reporter failure';
                                        push @{$progress_errors}, {
                                            update_id  => $summary->{update_id},
                                            chat_id    => $chat_id,
                                            message_id => $message_id,
                                            error      => $error,
                                        };
                                        $self->append_listener_audit_event(
                                            $paths,
                                            'progress.emit.failed',
                                            {
                                                update_id  => $summary->{update_id},
                                                message_id => $message_id,
                                                chat_id    => $chat_id,
                                                error      => $error,
                                            },
                                        );
                                    }
                                },
                              )
                            : ()
                        ),
                    );
                    return 0 if !defined $reply_message || $reply_message eq q{};
                    eval { $reporter->{emit}->('Sending final reply to Telegram') } if $reporter;
                    $self->dispatch_listener_reply(
                        chat_id             => $chat_id,
                        reply_to_message_id => $message_id,
                        reply_message       => $reply_message,
                    );
                    if ($reporter) {
                        eval { $reporter->{emit}->('Final reply sent') };
                        eval { $reporter->{finish}->() };
                    }
                    $self->append_listener_audit_event(
                        $paths,
                        'reply.sent',
                        {
                            update_id  => $summary->{update_id},
                            message_id => $message_id,
                            chat_id    => $chat_id,
                        },
                    );
                    return 1;
                };
                if ( $reply_mode eq 'claude-session' ) {
                    return $self->with_listener_typing_status(
                        $summary,
                        typing_errors => $typing_errors,
                        code          => $runner,
                    );
                }
                return $runner->();
            };
            if ( my $error = $@ ) {
                chomp $error;
                push @{$reply_errors}, {
                    update_id  => $summary->{update_id},
                    chat_id    => $chat_id,
                    message_id => $message_id,
                    error      => $error,
                };
                $self->append_listener_audit_event(
                    $paths,
                    'reply.failed',
                    {
                        update_id  => $summary->{update_id},
                        message_id => $message_id,
                        chat_id    => $chat_id,
                        error      => $error,
                    },
                );
            }
            elsif ($sent) {
                $replied++;
            }
        }
    );

    return { replied => $replied };
}

sub plugin_targets {
    my ($self) = @_;
    my @targets;
    push @targets, {
        plugin_root      => $self->resolve_path( $self->env_value('CLAUDE_PRIMARY_PLUGIN_ROOT') || '~/.claude/.tmp/plugins/plugins' ),
        marketplace_path => $self->resolve_path( $self->env_value('CLAUDE_PRIMARY_MARKETPLACE_PATH') || '~/.claude/.tmp/plugins/.agents/plugins/marketplace.json' ),
    };

    my $mirror_marketplace = $self->env_value('CLAUDE_MIRROR_MARKETPLACE_PATH') || '~/_claude/michael/.tmp/plugins/.agents/plugins/marketplace.json';
    my $mirror_plugin_root = $self->env_value('CLAUDE_MIRROR_PLUGIN_ROOT') || '~/_claude/michael/.tmp/plugins/plugins';
    my $resolved_mirror_marketplace = $self->resolve_path($mirror_marketplace);
    if ( -f $resolved_mirror_marketplace || -d dirname($resolved_mirror_marketplace) ) {
        push @targets, {
            plugin_root      => $self->resolve_path($mirror_plugin_root),
            marketplace_path => $resolved_mirror_marketplace,
        };
    }
    return @targets;
}

sub install_claude_launchers {
    my ($self) = @_;
    my $paths = $self->claude_launcher_paths;
    my $real_claude_path = eval { $self->resolve_real_claude_bin($paths) };
    $real_claude_path = undef if $@;
    $self->write_text_file( $paths->{real_bin_file}, $real_claude_path . "\n" )
      if defined $real_claude_path && $real_claude_path ne q{};
    my $dashboard_script = $self->dashboard_claude_launcher_script(
        real_claude_path => $real_claude_path,
        real_bin_file   => $paths->{real_bin_file},
        start_cli_path  => $paths->{start_cli_path},
    );
    $self->write_text_file( $paths->{dashboard_launcher_path}, $dashboard_script );
    chmod 0700, $paths->{dashboard_launcher_path} if !$self->is_windows;
    my $wrapper_script = $self->claude_handoff_wrapper_script(
        dashboard_launcher_path => $paths->{dashboard_launcher_path},
    );
    $self->write_text_file( $paths->{wrapper_path}, $wrapper_script );
    chmod 0700, $paths->{wrapper_path} if !$self->is_windows;
    return {
        wrapper_path            => $paths->{wrapper_path},
        dashboard_launcher_path => $paths->{dashboard_launcher_path},
        real_claude_path         => $real_claude_path,
        real_bin_file           => $paths->{real_bin_file},
    };
}

sub scaffold_plugin {
    my ( $self, %args ) = @_;
    my $plugin_root = $args{plugin_root};
    my $marketplace_path = $args{marketplace_path};
    my $token = $args{token};
    my $plugin_dir = File::Spec->catdir( $plugin_root, 'telegram-claude' );
    my $claude_plugin_dir = File::Spec->catdir( $plugin_dir, '.claude-plugin' );
    my $scripts_dir = File::Spec->catdir( $plugin_dir, 'scripts' );
    make_path($claude_plugin_dir);
    make_path($scripts_dir);
    make_path( dirname($marketplace_path) );

    $self->write_text_file(
        File::Spec->catfile( $claude_plugin_dir, 'plugin.json' ),
        $self->encode_pretty_json( $self->plugin_manifest ),
    );
    $self->write_text_file(
        File::Spec->catfile( $plugin_dir, '.mcp.json' ),
        $self->encode_pretty_json( $self->plugin_mcp_config ),
    );
    $self->write_text_file(
        File::Spec->catfile( $plugin_dir, '.env' ),
        'TELEGRAM_BOT_TOKEN=' . $token . "\n",
    );
    $self->write_text_file(
        File::Spec->catfile( $plugin_dir, 'README.md' ),
        $self->plugin_readme,
    );
    my $script_path = File::Spec->catfile( $scripts_dir, 'telegram_mcp.py' );
    $self->write_text_file( $script_path, $self->plugin_script_python );
    chmod 0700, $script_path;
    $self->update_marketplace($marketplace_path);
    return {
        plugin_dir       => $plugin_dir,
        marketplace_path => $marketplace_path,
        script_path      => $script_path,
    };
}

sub plugin_manifest {
    return {
        name        => 'telegram-claude',
        version     => '0.2.0',
        description => 'Local Claude Telegram MCP bridge installed by the telegram-claude DD skill.',
        author      => { name => 'Michael Vu' },
        homepage    => 'https://telegram.org/',
        license     => 'MIT',
        keywords    => [ 'telegram', 'claude', 'mcp', 'bot' ],
        mcpServers  => './.mcp.json',
        interface   => {
            displayName      => 'Telegram Claude',
            shortDescription => 'Poll and reply through a DD-managed Telegram collector',
            longDescription  => 'Use a local Telegram Bot API bridge for Claude through a generated stdio MCP server and a governed DD collector-owned polling loop.',
            developerName    => 'Michael Vu',
            category         => 'Productivity',
            capabilities     => [ 'Interactive', 'Write' ],
            websiteURL       => 'https://telegram.org/',
            privacyPolicyURL => 'https://telegram.org/privacy',
            termsOfServiceURL => 'https://telegram.org/tos',
            defaultPrompt    => [ 'Check Telegram updates, download files, and send replies through the generated local bridge' ],
            brandColor       => '#229ED9',
            screenshots      => [],
        },
    };
}

sub plugin_mcp_config {
    return {
        mcpServers => {
            'telegram-claude-bot' => {
                type    => 'stdio',
                command => 'python3',
                args    => [ './scripts/telegram_mcp.py' ],
                note    => 'Local Telegram Bot API MCP bridge generated by the telegram-claude DD skill.',
            },
        },
    };
}

sub plugin_readme {
    return <<'EOF';
# Telegram Claude Plugin

This local Claude plugin exposes a Telegram Bot API bridge over MCP.

Current mode:

- polling-first inbox access
- send text replies
- send photos
- send documents
- download incoming Telegram files locally
- auto-reply to `/start`

The bot token is loaded from the plugin-local `.env` file.

For managed two-way replies through the Dashboard collector runtime, use:

- `dashboard telegram-claude.start`

After `dashboard skills install telegram-claude`, the managed launch chain is:

- `claude`
- `~/.developer-dashboard/cli/claude`
- `telegram-claude/cli/start`
EOF
}

sub claude_config_path {
    my ($self) = @_;
    return File::Spec->catfile( $self->resolve_path('~/.developer-dashboard/config'), 'claude.json' );
}

sub read_claude_config {
    my ( $self, $path ) = @_;
    return {} if !-f $path;
    return decode_json( $self->read_text_file($path) );
}

sub write_claude_config {
    my ( $self, $path, $data ) = @_;
    $self->write_text_file( $path, $self->encode_pretty_json($data) );
    return $path;
}

sub now_string {
    my ($self) = @_;
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime;
    return sprintf(
        "%04d-%02d-%02d %02d:%02d:%02d",
        $year + 1900,
        $mon + 1, $mday, $hour, $min, $sec
    );
}

sub now_iso8601_z {
    my ($self) = @_;
    my ( $sec, $min, $hour, $mday, $mon, $year ) = gmtime;
    return sprintf(
        "%04d-%02d-%02dT%02d:%02d:%02dZ",
        $year + 1900,
        $mon + 1, $mday, $hour, $min, $sec
    );
}

sub claude_start_plan {
    my ( $self, $config, @argv ) = @_;
    my @claude_args = @argv;
    my $mapped_session = $self->mapped_claude_session_from_config($config);
    if ( defined $mapped_session && $mapped_session ne q{} && !$self->claude_args_already_resume(@argv) ) {
        @claude_args = ( '--resume', $mapped_session, @argv );
    }
    my $workspace_session_id = $self->workspace_session_id;
    my $collector_session_id = $workspace_session_id;
    my $claude_session_id = $mapped_session
      || $collector_session_id;
    my $start_collector = ( $self->env_value('TELEGRAM_BOT_TOKEN') && ( $self->env_value('TELEGRAM_CLAUDE_ENABLE_AUTOSTART') || q{} ) eq '1' ) ? 1 : 0;
    $start_collector = 0 if $self->start_reentry_guard_active;
    return {
        mode                => 'start',
        action              => 'exec',
        ticket              => $self->workspace_session_id,
        mapped_session      => $mapped_session,
        claude_args          => \@claude_args,
        real_claude_bin      => $self->resolve_real_claude_bin( $self->claude_launcher_paths ),
        start_collector      => $start_collector,
        workspace_session_id => $workspace_session_id,
        collector_session_id => $collector_session_id,
        collector_name       => $self->collector_name_for_session($collector_session_id),
        collector_cwd        => $self->{cwd},
        collector_command    => 'dashboard telegram-claude.check-message ' . $self->normalise_session_id($collector_session_id),
        claude_session_id     => $claude_session_id,
    };
}

sub ensure_startup_collector {
    my ( $self, $plan ) = @_;
    my $result = $self->ensure_collector_config(
        $plan->{collector_session_id},
        cwd => $plan->{collector_cwd},
    );
    $self->write_claude_target_session_id(
        $plan->{collector_session_id},
        $plan->{claude_session_id},
    );
    return $result;
}

sub restart_startup_collector {
    my ( $self, $plan ) = @_;
    my @command = ( 'dashboard', 'restart', 'collector', $plan->{collector_name} );
    if ( $self->{command_runner} ) {
        return $self->{command_runner}->( \@command, { plan => $plan } );
    }
    my $exit = system @command;
    die "Unable to restart collector $plan->{collector_name}\n" if $exit == -1 || ( $exit >> 8 ) != 0;
    return {
        command   => \@command,
        exit_code => $exit >> 8,
    };
}

sub stop_startup_collector {
    my ( $self, $session_id ) = @_;
    my $collector_name = $self->collector_name_for_session($session_id);
    my @command = ( 'dashboard', 'stop', 'collector', $collector_name );
    if ( $self->{command_runner} ) {
        return $self->{command_runner}->( \@command, { session_id => $session_id, collector_name => $collector_name } );
    }
    my $exit = system @command;
    die "Unable to stop collector $collector_name\n" if $exit == -1 || ( $exit >> 8 ) != 0;
    return {
        command   => \@command,
        exit_code => $exit >> 8,
    };
}

sub ensure_collector_config {
    my ( $self, $session_id, %args ) = @_;
    my $path = $self->dashboard_config_path;
    my $data = $self->read_json_file_or_default( $path, {} );
    $data = {} if ref($data) ne 'HASH';
    my $name = $self->collector_name_for_session($session_id);
    my $wanted = $self->collector_definition(
        $session_id,
        cwd => $args{cwd},
    );
    my @collectors = ref( $data->{collectors} ) eq 'ARRAY' ? @{ $data->{collectors} } : ();
    my @kept;
    my $seen = 0;
    my $removed_duplicates = 0;
    my $removed_workspace_conflicts = 0;
    for my $collector (@collectors) {
        if ( ref($collector) eq 'HASH' && defined $collector->{name} && $collector->{name} eq $name ) {
            if ( !$seen ) {
                push @kept, $wanted;
                $seen = 1;
            }
            else {
                $removed_duplicates++;
            }
            next;
        }
        if ( $self->collector_conflicts_with_workspace_session( $collector, $wanted ) ) {
            $removed_workspace_conflicts++;
            next;
        }
        push @kept, $collector;
    }
    push @kept, $wanted if !$seen;
    $data->{collectors} = \@kept;
    $self->write_text_file( $path, $self->encode_pretty_json($data) );
    return {
        config_path        => $path,
        collector_name     => $name,
        collector          => $wanted,
        created            => $seen ? 0 : 1,
        removed_duplicates => $removed_duplicates,
        removed_workspace_conflicts => $removed_workspace_conflicts,
    };
}

sub collector_definition {
    my ( $self, $session_id, %args ) = @_;
    my $cwd = defined $args{cwd} && $args{cwd} ne q{} ? $args{cwd} : $self->{cwd};
    return {
        name     => $self->collector_name_for_session($session_id),
        interval => 5,
        rotation => { lines => 100 },
        cwd      => $cwd,
        command  => 'dashboard telegram-claude.check-message ' . $self->normalise_session_id($session_id),
        mode     => 'singleton',
    };
}

sub collector_name_for_session {
    my ( $self, $session_id ) = @_;
    return 'telegram-claude-' . $self->normalise_session_id($session_id);
}

sub dashboard_config_path {
    my ($self) = @_;
    return File::Spec->catfile( $self->resolve_path('~/.developer-dashboard/config'), 'config.json' );
}

sub read_json_file_or_default {
    my ( $self, $path, $default ) = @_;
    return $default if !-f $path;
    return decode_json( $self->read_text_file($path) );
}

sub workspace_session_id {
    my ($self) = @_;
    my $shell_pwd = $self->env_value('PWD');
    if ( defined $shell_pwd && $shell_pwd ne q{} && File::Spec->file_name_is_absolute($shell_pwd) ) {
        return $self->normalise_session_id( $self->basename($shell_pwd) );
    }
    return $self->normalise_session_id( $self->basename( $self->{cwd} ) );
}

sub start_reentry_guard_active {
    my ($self) = @_;
    my $value = $self->env_value('TELEGRAM_CLAUDE_START_ACTIVE') || q{};
    return $value =~ /\A(?:1|true|yes|on)\z/i ? 1 : 0;
}

sub claude_args_already_resume {
    my ( $self, @argv ) = @_;
    my @remaining = @argv;
    while (@remaining) {
        my $arg = shift @remaining;
        return 1 if defined $arg && ( $arg eq '--resume' || $arg eq '-r' );
        if ( defined $arg && $arg eq '--model' ) {
            shift @remaining if @remaining;
            next;
        }
    }
    return 0;
}

sub collector_conflicts_with_workspace_session {
    my ( $self, $collector, $wanted ) = @_;
    return 0 if ref($collector) ne 'HASH';
    my $name = defined $collector->{name} ? $collector->{name} : q{};
    return 0 if $name !~ /\Atelegram-claude-/;
    my $cwd = defined $collector->{cwd} ? $collector->{cwd} : q{};
    return 0 if $cwd eq q{} || $cwd ne $wanted->{cwd};
    return 0 if $name eq $wanted->{name};
    return 1;
}

sub begin_check_message_session {
    my ( $self, $session_id, $paths ) = @_;
    my $pid_file = $paths->{pid_file};
    make_path( dirname($pid_file) ) if !-d dirname($pid_file);
    sysopen my $fh, $pid_file, O_RDWR | O_CREAT or die "Unable to open $pid_file: $!";
    if ( !flock( $fh, LOCK_EX | LOCK_NB ) ) {
        seek $fh, 0, 0;
        my $existing_pid = do { local $/; <$fh> };
        $existing_pid = q{} if !defined $existing_pid;
        $existing_pid =~ s/\s+\z//;
        return {
            already_running => 1,
            running_pid     => $existing_pid =~ /\A\d+\z/ ? 0 + $existing_pid : undef,
        };
    }
    seek $fh, 0, 0;
    truncate $fh, 0 or die "Unable to truncate $pid_file: $!";
    print {$fh} "$$\n" or die "Unable to write $pid_file: $!";
    seek $fh, 0, 0;
    $self->{check_message_session_locks}{$session_id} = $fh;
    return {
        already_running => 0,
        pid_file        => $pid_file,
    };
}

sub begin_listener_global_poll_session {
    my ( $self, $session_id, $shared_paths ) = @_;
    return {
        poll_owner       => 1,
        running_pid      => $$,
        owner_session_id => $session_id,
    } if $self->{global_poll_lock_fh};
    my $lock_file = $shared_paths->{poll_lock_file};
    make_path( dirname($lock_file) ) if !-d dirname($lock_file);
    sysopen my $fh, $lock_file, O_RDWR | O_CREAT or die "Unable to open $lock_file: $!";
    if ( !flock( $fh, LOCK_EX | LOCK_NB ) ) {
        seek $fh, 0, 0;
        my $content = do { local $/; <$fh> };
        my ( $running_pid, $owner_session_id ) = defined $content ? split /\s+/, $content, 2 : ();
        return {
            poll_owner       => 0,
            running_pid      => defined $running_pid && $running_pid =~ /\A\d+\z/ ? 0 + $running_pid : undef,
            owner_session_id => $owner_session_id,
        };
    }
    seek $fh, 0, 0;
    truncate $fh, 0 or die "Unable to truncate $lock_file: $!";
    print {$fh} "$$ $session_id\n" or die "Unable to write $lock_file: $!";
    seek $fh, 0, 0;
    $self->{global_poll_lock_fh} = $fh;
    return {
        poll_owner       => 1,
        running_pid      => $$,
        owner_session_id => $session_id,
    };
}

sub listener_target_for_summary {
    my ( $self, $summary, $default_session_id ) = @_;
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : undef;
    return ( $default_session_id, $self->listener_paths_for_session($default_session_id) ) if !defined $chat_id;
    my $paths = $self->listener_paths_for_session($default_session_id);
    my @paired_matches;
    my @pending_matches;
    for my $pairing_file ( glob File::Spec->catfile( $paths->{runtime_root}, '*', 'pairing.json' ) ) {
        my $other_dir = dirname($pairing_file);
        my $other_session_id = File::Basename::basename($other_dir);
        my $other_paths = $self->listener_paths_for_session($other_session_id);
        my $other_state = $self->read_listener_pairing_state($other_paths);
        if ( defined $other_state->{paired_chat_id} && $other_state->{paired_chat_id} eq $chat_id ) {
            push @paired_matches, {
                session_id => $other_session_id,
                paired_at  => $other_state->{paired_at} || q{},
            };
            next;
        }
        next if !defined $other_state->{pending_chat_id} || $other_state->{pending_chat_id} ne $chat_id;
        push @pending_matches, {
            session_id => $other_session_id,
            sent_at    => $other_state->{challenge_sent_at} || q{},
        };
    }
    if (@paired_matches) {
        for my $match (@paired_matches) {
            return ( $match->{session_id}, $self->listener_paths_for_session( $match->{session_id} ) )
              if $match->{session_id} eq $default_session_id;
        }
        @paired_matches = sort { $b->{paired_at} cmp $a->{paired_at} || $a->{session_id} cmp $b->{session_id} } @paired_matches;
        return ( $paired_matches[0]{session_id}, $self->listener_paths_for_session( $paired_matches[0]{session_id} ) );
    }
    if (@pending_matches) {
        for my $match (@pending_matches) {
            return ( $match->{session_id}, $self->listener_paths_for_session( $match->{session_id} ) )
              if $match->{session_id} eq $default_session_id;
        }
        @pending_matches = sort { $b->{sent_at} cmp $a->{sent_at} || $a->{session_id} cmp $b->{session_id} } @pending_matches;
        return ( $pending_matches[0]{session_id}, $self->listener_paths_for_session( $pending_matches[0]{session_id} ) );
    }
    my $claim = $self->read_listener_pairing_claim( $self->listener_shared_paths_for_session($default_session_id) );
    if ( defined $claim->{session_id} && $claim->{session_id} ne q{} ) {
        return ( $claim->{session_id}, $self->listener_paths_for_session( $claim->{session_id} ) );
    }
    return ( $default_session_id, $self->listener_paths_for_session($default_session_id) );
}

sub pid_is_running {
    my ( $self, $pid ) = @_;
    if ( $self->{pid_check_runner} ) {
        return $self->{pid_check_runner}->($pid) ? 1 : 0;
    }
    return kill 0, $pid;
}

sub signal_process {
    my ( $self, $signal, $pid ) = @_;
    if ( $self->{process_signal_runner} ) {
        my $handled = $self->{process_signal_runner}->( $signal, $pid );
        return $handled ? 1 : 0;
    }
    return kill $signal, $pid;
}

sub recycle_check_message_session {
    my ( $self, $session_id ) = @_;
    return 0 if !defined $session_id || $session_id eq q{};
    my $paths = $self->listener_paths_for_session($session_id);
    my $pid_file = $paths->{pid_file};
    my %pids;
    my $recycled = 0;
    if ( -f $pid_file ) {
        my $pid = $self->read_text_file($pid_file);
        $pid =~ s/\s+\z//;
        if ( $pid eq q{} || $pid !~ /\A\d+\z/ ) {
            unlink $pid_file;
        }
        elsif ( !$self->pid_is_running($pid) ) {
            unlink $pid_file;
        }
        else {
            $pids{$pid} = 1;
        }
    }
    for my $row ( $self->stale_check_message_process_rows($session_id) ) {
        next if !$row->{pid};
        $pids{ $row->{pid} } = 1;
    }
    return 0 if !%pids && !-f $pid_file;
    for my $target_pid ( sort { $a <=> $b } keys %pids ) {
        next if !$self->pid_is_running($target_pid);
        $recycled = 1;
        $self->signal_process( 'TERM', $target_pid );
        my $remaining_polls = 10;
        while ( $remaining_polls-- > 0 ) {
            last if !$self->pid_is_running($target_pid);
            $self->listener_pause_seconds(1);
        }
        if ( $self->pid_is_running($target_pid) ) {
            $self->signal_process( 'KILL', $target_pid );
            for ( 1 .. 5 ) {
                last if !$self->pid_is_running($target_pid);
                $self->listener_pause_seconds(1);
            }
        }
    }
    unlink $pid_file if -f $pid_file && !grep { $self->pid_is_running($_) } keys %pids;
    return $recycled;
}

sub stale_check_message_process_rows {
    my ( $self, $session_id ) = @_;
    return () if !defined $session_id || $session_id eq q{};
    my @rows;
    for my $row ( $self->claude_process_rows ) {
        next if !$row->{cmd};
        next if $row->{cmd} !~ /\btelegram-claude\b/;
        next if $row->{cmd} !~ /\bcheck-message\b\s+\Q$session_id\E(?:\s|\z)/;
        push @rows, $row;
    }
    return @rows;
}

sub stale_claude_resume_process_rows {
    my ( $self, $session_id ) = @_;
    return () if !defined $session_id || $session_id eq q{};
    my %freshest_by_tty;
    my @rows = sort {
        ( $a->{etimes} // 1_000_000_000 ) <=> ( $b->{etimes} // 1_000_000_000 )
          || $b->{pid} <=> $a->{pid}
    } grep {
             $_->{cmd}
          && $_->{cmd} =~ /\bclaude\b/
          && $_->{cmd} =~ /(?:--resume|-r)\s+\Q$session_id\E(?:\s|\z)/
          && $_->{tty}
          && $_->{tty} ne '?'
    } $self->claude_process_rows;
    my @stale;
    for my $row (@rows) {
        my $pane_id = $self->discover_tmux_pane_for_tty( $row->{tty} );
        next if !defined $pane_id || $pane_id eq q{};
        if ( !$freshest_by_tty{ $row->{tty} } ) {
            $freshest_by_tty{ $row->{tty} } = $row;
            next;
        }
        next if ( $row->{ppid} // 0 ) != 1;
        push @stale, {
            %{$row},
            pane_id => $pane_id,
        };
    }
    return @stale;
}

sub prune_stale_claude_resume_processes {
    my ( $self, $session_id, $paths ) = @_;
    my @stale = $self->stale_claude_resume_process_rows($session_id);
    my @pruned;
    for my $row (@stale) {
        my $pid = $row->{pid};
        next if !$pid || !$self->pid_is_running($pid);
        $self->signal_process( 'TERM', $pid );
        for ( 1 .. 3 ) {
            last if !$self->pid_is_running($pid);
            $self->listener_pause_seconds(1);
        }
        if ( $self->pid_is_running($pid) ) {
            $self->signal_process( 'KILL', $pid );
            for ( 1 .. 2 ) {
                last if !$self->pid_is_running($pid);
                $self->listener_pause_seconds(1);
            }
        }
        next if $self->pid_is_running($pid);
        push @pruned, $pid;
        $self->append_listener_audit_event(
            $paths,
            'claude.resume.pruned',
            {
                session_id => $session_id,
                pid        => $pid,
                tty        => $row->{tty},
                pane_id    => $row->{pane_id},
                cmd        => $row->{cmd},
            },
        );
    }
    return @pruned;
}

sub start_listener_if_needed {
    my ( $self, $session_id, %options ) = @_;
    my $paths = $self->listener_paths_for_session($session_id);
    my $listener_command = $self->listener_command_path;
    make_path( $paths->{runtime_dir} ) if !-d $paths->{runtime_dir};
    if ( -f $paths->{pid_file} ) {
        my $existing_pid = $self->read_text_file( $paths->{pid_file} );
        $existing_pid =~ s/\s+\z//;
        if ( $existing_pid ne q{} && kill 0, $existing_pid ) {
            return {
                listener_running    => 1,
                listener_session_id => $session_id,
                pid                 => $existing_pid,
                %{$paths},
            };
        }
        unlink $paths->{pid_file};
    }

    if ( $self->{listener_start_runner} ) {
        my $pid = defined $self->{listener_start_pid} ? $self->{listener_start_pid} : $$;
        $self->{listener_start_runner}->( $session_id, $paths, \%options );
        $self->write_text_file( $paths->{pid_file}, "$pid\n" );
        return {
            listener_running    => 0,
            listener_session_id => $session_id,
            pid                 => $pid,
            %{$paths},
        };
    }

    my $pid = $self->{fork_runner} ? $self->{fork_runner}->() : fork();
    die "Unable to fork telegram listener: $!" if !defined $pid;
    if ( $pid == 0 ) {
        open STDIN,  '<', '/dev/null'         or die "Unable to reopen stdin: $!";
        open STDOUT, '>>', $paths->{log_file} or die "Unable to reopen stdout: $!";
        open STDERR, '>>', $paths->{log_file} or die "Unable to reopen stderr: $!";
        $ENV{TELEGRAM_CLAUDE_SESSION_ID} = $session_id;
        $ENV{TELEGRAM_CLAUDE_LISTENER_PRIME_LATEST} = 1;
        $ENV{TELEGRAM_CLAUDE_LISTENER_MODE} = $options{mode} if defined $options{mode} && $options{mode} ne q{};
        $ENV{TELEGRAM_CLAUDE_TARGET_SESSION_ID} = $options{claude_session_id} if defined $options{claude_session_id} && $options{claude_session_id} ne q{};
        my @command = ( $listener_command, 0, 30 );
        push @command, $options{reply_text} if defined $options{reply_text} && $options{reply_text} ne q{};
        exec { $listener_command } @command or die "Unable to exec $listener_command: $!";
    }

    $self->write_text_file( $paths->{pid_file}, "$pid\n" );
    return {
        listener_running   => 0,
        listener_session_id => $session_id,
        pid                => $pid,
        %{$paths},
    };
}

sub listener_command_path {
    my ($self) = @_;
    return File::Spec->catfile( $self->{skill_root}, 'cli', 'check-message' );
}

sub plugin_script_python {
    my ($self) = @_;
    return $self->read_text_file( $self->plugin_script_source_path );
}

sub plugin_script_source_path {
    my ($self) = @_;
    return File::Spec->catfile( $self->{skill_root}, 'scripts', 'telegram_mcp.py' );
}

sub claude_launcher_paths {
    my ($self) = @_;
    my $wrapper_dir = $self->select_claude_wrapper_dir;
    my $runtime_root = $self->resolve_path('~/.telegram-claude');
    my $dashboard_cli_root = $self->resolve_path('~/.developer-dashboard/cli');
    return {
        wrapper_dir             => $wrapper_dir,
        wrapper_path            => File::Spec->catfile( $wrapper_dir, $self->claude_wrapper_filename ),
        dashboard_cli_root      => $dashboard_cli_root,
        dashboard_launcher_path => File::Spec->catfile( $dashboard_cli_root, 'claude' ),
        start_cli_path          => File::Spec->catfile( $self->{skill_root}, 'cli', 'start' ),
        real_bin_file           => File::Spec->catfile( $runtime_root, '.claude-real-bin' ),
    };
}

sub select_claude_wrapper_dir {
    my ($self) = @_;
    my @preferred = $self->is_windows
      ? map { $self->resolve_path($_) } qw(~/perl5/bin ~/bin ~/.local/bin)
      : map { $self->resolve_path($_) } qw(~/.local/bin ~/bin);
    my %preferred = map { $_ => 1 } @preferred;
    my @path_entries = split /\Q@{[ $self->path_separator ]}\E/, ( $self->env_value('PATH') || $ENV{PATH} || q{} );
    my %seen;
    my @ordered = grep { defined $_ && $_ ne q{} && !$seen{$_}++ } map { $self->resolve_path($_) } @path_entries;
    my @candidates = grep { $preferred{$_} } @ordered;
    push @candidates, grep { !$seen{$_}++ } @preferred;
    my $wrapper_name = $self->claude_wrapper_filename;

    for my $dir (@candidates) {
        my $path = File::Spec->catfile( $dir, $wrapper_name );
        next if !-f $path;
        my $content = eval { $self->read_text_file($path) };
        next if $@;
        return $dir if $content =~ /telegram-claude-managed-claude-wrapper/;
    }

    for my $dir (@candidates) {
        my $path = File::Spec->catfile( $dir, $wrapper_name );
        return $dir if !-e $path;
    }

    return $candidates[0];
}

sub resolve_real_claude_bin {
    my ( $self, $paths ) = @_;
    my $explicit = $self->env_value('CLAUDE_REAL_BIN');
    return $explicit if defined $explicit && $explicit ne q{};

    my $detected = $self->find_command_on_path('claude');
    my %skip = map { $_ => 1 } grep { defined $_ && $_ ne q{} } ( $paths->{wrapper_path}, $paths->{dashboard_launcher_path} );
    if ( defined $detected && $detected ne q{} && !$skip{$detected} ) {
        return $detected;
    }
    if ( -f $paths->{real_bin_file} ) {
        my $stored = $self->read_text_file( $paths->{real_bin_file} );
        $stored =~ s/\s+\z//;
        return $stored if $stored ne q{};
    }
    die "Unable to resolve the real claude binary path\n";
}

sub real_claude_version_output {
    my ($self) = @_;
    return $self->{claude_version_runner}->() if $self->{claude_version_runner};

    my $real_claude_bin = $self->resolve_real_claude_bin( $self->claude_launcher_paths );
    open my $fh, '-|', $real_claude_bin, '--version'
      or die "Unable to run $real_claude_bin --version: $!";
    local $/;
    my $output = <$fh>;
    close $fh or die "Unable to read $real_claude_bin --version output: $!";
    die "Unexpected empty version output from $real_claude_bin --version\n"
      if !defined $output || $output eq q{};
    return $output;
}

sub explicit_start_ollama_model {
    my ($self) = @_;
    my $ollama_model = $self->env_value('TELEGRAM_CLAUDE_OLLAMA_MODEL');
    return undef if !defined $ollama_model || $ollama_model eq q{};
    my $default_model = 'qwen3.5:397b-cloud';
    return $default_model if $ollama_model eq '1' || $ollama_model eq '2';
    return $ollama_model;
}

sub e2e_runtime_root {
    my ($self) = @_;
    return File::Spec->catdir( $self->{home}, '.developer-dashboard', 'state', 'telegram-claude', 'e2e' );
}

sub e2e_env_file {
    my ($self) = @_;
    return File::Spec->catfile( $self->e2e_runtime_root, 'e2e.env' );
}

sub e2e_state_file {
    my ($self) = @_;
    return File::Spec->catfile( $self->e2e_runtime_root, 'state.json' );
}

sub e2e_chrome_profile_dir {
    my ($self) = @_;
    return File::Spec->catdir( $self->e2e_runtime_root, 'chrome-profile' );
}

sub e2e_compose_file {
    my ($self) = @_;
    return File::Spec->catfile( $self->{skill_root}, 'docker-compose.e2e.yml' );
}

sub e2e_dockerfile {
    my ($self) = @_;
    return File::Spec->catfile( $self->{skill_root}, 'docker', 'e2e', 'Dockerfile' );
}

sub e2e_project_name {
    return 'telegram-claude-e2e';
}

sub e2e_runtime_user {
    return 'dashboard';
}

sub e2e_host_uid {
    my ($self) = @_;
    my $uid = $self->env_value('TELEGRAM_CLAUDE_E2E_HOST_UID');
    return defined $uid && $uid ne q{} ? $uid : 1000;
}

sub e2e_host_gid {
    my ($self) = @_;
    my $gid = $self->env_value('TELEGRAM_CLAUDE_E2E_HOST_GID');
    return defined $gid && $gid ne q{} ? $gid : 1000;
}

sub e2e_novnc_port { return 25900 }
sub e2e_vnc_port { return 25901 }
sub e2e_chrome_debug_port { return 29222 }

sub e2e_telegram_url {
    return 'https://web.telegram.org/a/';
}

sub e2e_metadata {
    my ($self) = @_;
    return {
        compose_file       => $self->e2e_compose_file,
        dockerfile         => $self->e2e_dockerfile,
        env_file           => $self->e2e_env_file,
        state_file         => $self->e2e_state_file,
        chrome_profile_dir => $self->e2e_chrome_profile_dir,
        project_name       => $self->e2e_project_name,
        workspace_path     => $self->{cwd},
        runtime_user       => $self->e2e_runtime_user,
        host_uid           => 0 + $self->e2e_host_uid,
        host_gid           => 0 + $self->e2e_host_gid,
        novnc_port         => $self->e2e_novnc_port,
        vnc_port           => $self->e2e_vnc_port,
        chrome_debug_port  => $self->e2e_chrome_debug_port,
        novnc_url          => 'http://127.0.0.1:' . $self->e2e_novnc_port . '/vnc.html?autoconnect=1&resize=scale',
        chrome_debug_url   => 'http://127.0.0.1:' . $self->e2e_chrome_debug_port,
        telegram_url       => $self->e2e_telegram_url,
    };
}

sub write_e2e_env_file {
    my ($self) = @_;
    make_path( $self->e2e_runtime_root ) if !-d $self->e2e_runtime_root;
    make_path( $self->e2e_chrome_profile_dir ) if !-d $self->e2e_chrome_profile_dir;
    my $content = join q{},
      'TELEGRAM_CLAUDE_E2E_WORKSPACE_PATH=', $self->{cwd}, "\n",
      'TELEGRAM_CLAUDE_E2E_RUNTIME_USER=',   $self->e2e_runtime_user, "\n",
      'TELEGRAM_CLAUDE_E2E_HOST_UID=',       $self->e2e_host_uid, "\n",
      'TELEGRAM_CLAUDE_E2E_HOST_GID=',       $self->e2e_host_gid, "\n",
      'TELEGRAM_CLAUDE_E2E_NOVNC_PORT=',     $self->e2e_novnc_port, "\n",
      'TELEGRAM_CLAUDE_E2E_VNC_PORT=',       $self->e2e_vnc_port, "\n",
      'TELEGRAM_CLAUDE_E2E_CHROME_DEBUG_PORT=', $self->e2e_chrome_debug_port, "\n",
      'TELEGRAM_CLAUDE_E2E_CHROME_PROFILE_DIR=', $self->e2e_chrome_profile_dir, "\n",
      'TELEGRAM_CLAUDE_E2E_TELEGRAM_URL=',   $self->e2e_telegram_url, "\n";
    return $self->write_text_file( $self->e2e_env_file, $content );
}

sub e2e_stack_running {
    my ($self) = @_;
    return 0 if !-f $self->e2e_env_file;
    my $result = $self->run_e2e_compose_command('ps');
    my $stdout = $result->{stdout} || q{};
    return $stdout =~ /\S/ ? 1 : 0;
}

sub e2e_compose_command {
    my ( $self, @args ) = @_;
    my $docker_bin = $self->env_value('TELEGRAM_CLAUDE_E2E_DOCKER_BIN') || 'docker';
    my @command = (
        $docker_bin,
        'compose',
        '-f', $self->e2e_compose_file,
        '--env-file', $self->e2e_env_file,
        '-p', $self->e2e_project_name,
        @args,
    );
    return @command;
}

sub run_e2e_compose_command {
    my ( $self, @args ) = @_;
    my @command = $self->e2e_compose_command(@args);
    if ( $self->{command_runner} ) {
        return $self->{command_runner}->( \@command, { mode => 'e2e', args => \@args } );
    }
    if ( @args == 1 && $args[0] eq 'ps' ) {
        open my $fh, '-|', @command or die "Unable to run @command: $!";
        local $/;
        my $stdout = <$fh> // q{};
        close $fh or die "Unable to read @command output: $!";
        return {
            command   => \@command,
            exit_code => 0,
            stdout    => $stdout,
        };
    }
    my $exit = system @command;
    die "Command failed: @command\n" if $exit == -1 || ( $exit >> 8 ) != 0;
    return {
        command   => \@command,
        exit_code => 0,
        stdout    => q{},
    };
}

sub inject_ollama_claude_args {
    my ( $self, $ollama_model, @argv ) = @_;
    return @argv if !defined $ollama_model || $ollama_model eq q{};
    return @argv if $self->argv_already_targets_ollama(@argv);
    return ( '--model', $ollama_model, @argv );
}

sub argv_already_targets_ollama {
    my ( $self, @argv ) = @_;
    for ( my $i = 0; $i < @argv; $i++ ) {
        next if !defined $argv[$i];
        return 1 if $argv[$i] eq '--model' && defined $argv[ $i + 1 ];
    }
    return 0;
}

sub dashboard_claude_launcher_script {
    my ( $self, %args ) = @_;
    my $start_cli_path = $args{start_cli_path};
    $start_cli_path =~ s{\\}{\\\\}g;
    $start_cli_path =~ s{'}{\\'}g;
    return <<"EOF";
#!/usr/bin/env perl
# telegram-claude-managed-dashboard-claude-launcher
use strict;
use warnings;
my \$start_cli_path = '$start_cli_path';
if ( \$^O eq 'MSWin32' ) {
    system \$^X, \$start_cli_path, \@ARGV;
    my \$status = \$?;
    my \$exit_code = \$status > 255 ? \$status >> 8 : \$status;
    exit \$exit_code;
}
exec \$^X, \$start_cli_path, \@ARGV or die "Unable to exec \$^X \$start_cli_path: \$!";
EOF
}

sub claude_handoff_wrapper_script {
    my ( $self, %args ) = @_;
    my $dashboard_launcher_path = $args{dashboard_launcher_path};
    if ( $self->is_windows ) {
        return <<"EOF";
\@echo off
rem telegram-claude-managed-claude-wrapper
perl "$dashboard_launcher_path" %*
exit /b %ERRORLEVEL%
EOF
    }
    return <<"EOF";
#!/bin/sh
# telegram-claude-managed-claude-wrapper
set -eu
exec "$dashboard_launcher_path" "\$@"
EOF
}

sub is_windows {
    my ($self) = @_;
    return ( $self->{os} || q{} ) eq 'MSWin32' ? 1 : 0;
}

sub path_separator {
    my ($self) = @_;
    return q{;} if $self->is_windows;
    return $Config::Config{path_sep} || q{:};
}

sub claude_wrapper_filename {
    my ($self) = @_;
    return $self->is_windows ? 'claude.cmd' : 'claude';
}

sub find_command_on_path {
    my ( $self, $name ) = @_;
    my @path_entries = split /\Q@{[ $self->path_separator ]}\E/, ( $self->env_value('PATH') || $ENV{PATH} || q{} );
    my %seen;
    for my $dir (@path_entries) {
        next if !defined $dir || $dir eq q{};
        my $resolved_dir = $self->resolve_path($dir);
        for my $candidate ( $self->path_command_candidates($name) ) {
            my $path = File::Spec->catfile( $resolved_dir, $candidate );
            my $key = lc $path;
            next if $seen{$key}++;
            next if !-f $path;
            return $path if $self->is_windows || -x $path;
        }
    }
    return undef;
}

sub path_command_candidates {
    my ( $self, $name ) = @_;
    my @candidates = ($name);
    if ( $self->is_windows && $name !~ /\.[^\\\/.]+\z/ ) {
        my @extensions = split /;/, ( $self->env_value('PATHEXT') || $ENV{PATHEXT} || '.COM;.EXE;.BAT;.CMD' );
        push @candidates, map { $name . lc($_) } @extensions;
        push @candidates, map { $name . uc($_) } @extensions;
    }
    my %seen;
    return grep { defined $_ && $_ ne q{} && !$seen{$_}++ } @candidates;
}

sub update_marketplace {
    my ( $self, $path ) = @_;
    my $data;
    if ( -f $path ) {
        $data = decode_json( $self->read_text_file($path) );
    }
    else {
        $data = {
            name      => 'local-plugins',
            interface => { displayName => 'Local plugins' },
            plugins   => [],
        };
    }
    my $entry = {
        name   => 'telegram-claude',
        source => {
            source => 'local',
            path   => './plugins/telegram-claude',
        },
        policy => {
            installation  => 'AVAILABLE',
            authentication => 'ON_INSTALL',
        },
        category => 'Productivity',
    };
    my $found = 0;
    for my $plugin ( @{ $data->{plugins} } ) {
        next if $plugin->{name} ne 'telegram-claude';
        %{$plugin} = %{$entry};
        $found = 1;
    }
    push @{ $data->{plugins} }, $entry if !$found;
    $self->write_text_file( $path, $self->encode_pretty_json($data) );
}

sub summarise_update {
    my ( $self, $update ) = @_;
    my $message = $update->{message} || $update->{edited_message} || {};
    my $chat = $message->{chat} || {};
    my $photos = $message->{photo} || [];
    my $best_photo = @{$photos} ? $photos->[-1] : undef;
    return {
        update_id  => $update->{update_id},
        message_id => $message->{message_id},
        date       => $message->{date},
        chat       => {
            id         => $chat->{id},
            type       => $chat->{type},
            title      => $chat->{title},
            username   => $chat->{username},
            first_name => $chat->{first_name},
            last_name  => $chat->{last_name},
        },
        from     => $message->{from},
        text     => $message->{text},
        caption  => $message->{caption},
        photo    => $best_photo,
        document => $message->{document},
        audio    => $message->{audio},
        video    => $message->{video},
        voice    => $message->{voice},
    };
}

sub hydrate_summary_media_paths {
    my ( $self, $summary ) = @_;
    for my $descriptor ( $self->summary_media_descriptors($summary) ) {
        my $download = $self->download_telegram_file_id(
            $descriptor->{file_id},
            File::Spec->catdir( $self->listener_paths->{runtime_dir}, 'downloads', 'update-' . $summary->{update_id} ),
            $descriptor->{filename},
        );
        $summary->{ $descriptor->{field} }{local_path} = $download->{saved_to};
        $summary->{ $descriptor->{field} }{telegram_file_path} = $download->{telegram_file_path};
    }
    return $summary;
}

sub summary_media_descriptors {
    my ( $self, $summary ) = @_;
    my @descriptors;
    push @descriptors, {
        field    => 'photo',
        file_id  => $summary->{photo}{file_id},
        filename => 'photo-' . $summary->{update_id} . '.jpg',
    } if $summary->{photo} && $summary->{photo}{file_id};
    push @descriptors, {
        field    => 'document',
        file_id  => $summary->{document}{file_id},
        filename => $self->safe_filename( $summary->{document}{file_name} || 'document-' . $summary->{update_id} . '.bin' ),
    } if $summary->{document} && $summary->{document}{file_id};
    push @descriptors, {
        field    => 'audio',
        file_id  => $summary->{audio}{file_id},
        filename => $self->safe_filename( $summary->{audio}{title} || 'audio-' . $summary->{update_id} ) . '.bin',
    } if $summary->{audio} && $summary->{audio}{file_id};
    push @descriptors, {
        field    => 'video',
        file_id  => $summary->{video}{file_id},
        filename => 'video-' . $summary->{update_id} . '.bin',
    } if $summary->{video} && $summary->{video}{file_id};
    push @descriptors, {
        field    => 'voice',
        file_id  => $summary->{voice}{file_id},
        filename => 'voice-' . $summary->{update_id} . '.bin',
    } if $summary->{voice} && $summary->{voice}{file_id};
    return @descriptors;
}

sub download_telegram_file_id {
    my ( $self, $file_id, $target_dir, $filename ) = @_;
    my $file = $self->telegram_get( 'getFile', { file_id => $file_id } )->{result};
    my $bytes = $self->telegram_download( $file->{file_path} );
    make_path($target_dir) if !-d $target_dir;
    my $name = $filename || $self->basename( $file->{file_path} );
    my $path = File::Spec->catfile( $target_dir, $name );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    binmode $fh;
    print {$fh} $bytes;
    close $fh or die "Unable to close $path: $!";
    return { file_id => $file_id, telegram_file_path => $file->{file_path}, saved_to => $path, bytes => length $bytes };
}

sub telegram_get {
    my ( $self, $method, $params ) = @_;
    if ( $self->{get_runner} ) {
        return $self->{get_runner}->( $method, $params || {} );
    }
    my $url = URI->new( $self->telegram_api_base . '/' . $method );
    $url->query_form( %{ $params || {} } ) if $params && %{ $params || {} };
    my $request = GET( $url->as_string );
    my $response = $self->{ua}->request($request);
    die "Telegram GET failed for $method: " . $response->status_line . "\n" if !$response->is_success;
    my $payload = decode_json( $response->decoded_content );
    die "Telegram GET failed for $method: " . encode_json($payload) . "\n" if !$payload->{ok};
    return $payload;
}

sub telegram_post {
    my ( $self, $method, $params ) = @_;
    if ( $self->{post_runner} ) {
        return $self->{post_runner}->( $method, $params || {}, {} );
    }
    my $url = $self->telegram_api_base . '/' . $method;
    my $request = POST( $url, Content => [ %{ $params || {} } ] );
    my $response = $self->{ua}->request($request);
    die "Telegram POST failed for $method: " . $response->status_line . "\n" if !$response->is_success;
    my $payload = decode_json( $response->decoded_content );
    die "Telegram POST failed for $method: " . encode_json($payload) . "\n" if !$payload->{ok};
    return $payload;
}

sub telegram_post_file {
    my ( $self, $method, $params, $files ) = @_;
    if ( $self->{post_runner} ) {
        return $self->{post_runner}->( $method, $params || {}, $files || {} );
    }
    my @content;
    for my $key ( sort keys %{ $params || {} } ) {
        push @content, $key => $params->{$key};
    }
    for my $key ( sort keys %{ $files || {} } ) {
        push @content, $key => [ $files->{$key} ];
    }
    my $url = $self->telegram_api_base . '/' . $method;
    my $request = POST( $url, Content_Type => 'form-data', Content => \@content );
    my $response = $self->{ua}->request($request);
    die "Telegram POST failed for $method: " . $response->status_line . "\n" if !$response->is_success;
    my $payload = decode_json( $response->decoded_content );
    die "Telegram POST failed for $method: " . encode_json($payload) . "\n" if !$payload->{ok};
    return $payload;
}

sub dispatch_listener_reply {
    my ( $self, %args ) = @_;
    my $chat_id = $args{chat_id};
    my $reply_to_message_id = $args{reply_to_message_id};
    my $reply_message = $args{reply_message};
    my $directive = $self->parse_telegram_reply_directive($reply_message);
    if ( $directive->{kind} eq 'attachment' ) {
        my %params = (
            chat_id => $chat_id,
            ( defined $directive->{caption} && $directive->{caption} ne q{} ? ( caption => $directive->{caption} ) : () ),
            ( defined $reply_to_message_id ? ( reply_to_message_id => $reply_to_message_id ) : () ),
        );
        return $self->telegram_post_file( 'sendPhoto', \%params, { photo => $directive->{path} } )
          if $directive->{type} eq 'photo';
        return $self->telegram_post_file( 'sendAudio', \%params, { audio => $directive->{path} } )
          if $directive->{type} eq 'audio';
        return $self->telegram_post_file( 'sendDocument', \%params, { document => $directive->{path} } );
    }
    return $self->telegram_post(
        'sendMessage',
        {
            chat_id             => $chat_id,
            text                => $directive->{text},
            reply_to_message_id => $reply_to_message_id,
        }
    );
}

sub parse_telegram_reply_directive {
    my ( $self, $reply ) = @_;
    my @lines = split /\n/, ( defined $reply ? $reply : q{} );
    my %directive;
    my @body;
    for my $line (@lines) {
        if ( $line =~ /\Atelegram_attachment_type=(photo|audio|document)\z/ ) {
            $directive{type} = $1;
            next;
        }
        if ( $line =~ /\Atelegram_attachment_path=(.+)\z/ ) {
            $directive{path} = $1;
            next;
        }
        if ( $line =~ /\Atelegram_attachment_caption=(.*)\z/ ) {
            $directive{caption} = $1;
            next;
        }
        push @body, $line;
    }
    if ( defined $directive{type} && defined $directive{path} ) {
        $directive{kind} = 'attachment';
        $directive{caption} = join "\n", @body if !defined $directive{caption} && @body;
        return \%directive;
    }
    return {
        kind => 'text',
        text => $reply,
    };
}

sub telegram_download {
    my ( $self, $file_path ) = @_;
    if ( $self->{download_runner} ) {
        return $self->{download_runner}->( $self->telegram_file_base . '/' . $file_path );
    }
    my $response = $self->{ua}->get( $self->telegram_file_base . '/' . $file_path );
    die "Telegram download failed for $file_path: " . $response->status_line . "\n" if !$response->is_success;
    return $response->decoded_content( charset => 'none' );
}

sub telegram_api_base {
    my ($self) = @_;
    return 'https://api.telegram.org/bot' . $self->resolve_token;
}

sub telegram_file_base {
    my ($self) = @_;
    return 'https://api.telegram.org/file/bot' . $self->resolve_token;
}

sub listener_paths {
    my ($self) = @_;
    return $self->listener_paths_for_session( $self->listener_session_id );
}

sub listener_runtime_root {
    my ($self) = @_;
    my $configured = $self->env_value('TELEGRAM_CLAUDE_RUNTIME_DIR') || q{};
    return $self->resolve_path($configured) if $configured ne q{};
    return $self->resolve_path('~/.telegram-claude');
}

sub legacy_listener_runtime_root {
    my ($self) = @_;
    return $self->resolve_path('~/.telegram-claude');
}

sub listener_shared_runtime_root {
    my ($self) = @_;
    my $base_root = $self->listener_runtime_root;
    my $token = eval { $self->resolve_token };
    my $token_key = ( defined $token && !$@ && $token ne q{} ) ? sha1_hex($token) : 'default';
    return File::Spec->catdir( $base_root, '.shared', $token_key );
}

sub legacy_token_listener_runtime_root {
    my ($self) = @_;
    my $base_root = $self->resolve_path('~/.telegram-claude');
    my $token = eval { $self->resolve_token };
    if ( defined $token && !$@ && $token ne q{} ) {
        return File::Spec->catdir( $base_root, sha1_hex($token) );
    }
    return File::Spec->catdir( $base_root, 'default' );
}

sub listener_paths_for_session {
    my ( $self, $session_id ) = @_;
    my $runtime_root = $self->listener_runtime_root;
    my $runtime_dir = File::Spec->catdir( $runtime_root, $self->normalise_session_id($session_id) );
    return {
        runtime_root => $runtime_root,
        runtime_dir  => $runtime_dir,
        offset_file  => File::Spec->catfile( $runtime_dir, 'listener.offset' ),
        inbox_file   => File::Spec->catfile( $runtime_dir, 'listener.inbox.jsonl' ),
        pid_file     => File::Spec->catfile( $runtime_dir, 'listener.pid' ),
        log_file     => File::Spec->catfile( $runtime_dir, 'listener.log' ),
        audit_file   => File::Spec->catfile( $runtime_dir, 'audit.jsonl' ),
        audit_flag_file => File::Spec->catfile( $runtime_dir, 'audit.enabled' ),
        target_session_file => File::Spec->catfile( $runtime_dir, 'claude.session' ),
        transcript_cursor_file => File::Spec->catfile( $runtime_dir, 'transcript.cursor' ),
        pairing_state_file => File::Spec->catfile( $runtime_dir, 'pairing.json' ),
        live_pane_file => File::Spec->catfile( $runtime_dir, 'live-pane' ),
    };
}

sub legacy_listener_paths_for_session {
    my ( $self, $session_id ) = @_;
    my $runtime_root = $self->legacy_listener_runtime_root;
    my $runtime_dir = File::Spec->catdir( $runtime_root, $self->normalise_session_id($session_id) );
    return {
        runtime_root => $runtime_root,
        runtime_dir  => $runtime_dir,
        offset_file  => File::Spec->catfile( $runtime_dir, 'listener.offset' ),
        inbox_file   => File::Spec->catfile( $runtime_dir, 'listener.inbox.jsonl' ),
        pid_file     => File::Spec->catfile( $runtime_dir, 'listener.pid' ),
        log_file     => File::Spec->catfile( $runtime_dir, 'listener.log' ),
        audit_file   => File::Spec->catfile( $runtime_dir, 'audit.jsonl' ),
        audit_flag_file => File::Spec->catfile( $runtime_dir, 'audit.enabled' ),
        target_session_file => File::Spec->catfile( $runtime_dir, 'claude.session' ),
        transcript_cursor_file => File::Spec->catfile( $runtime_dir, 'transcript.cursor' ),
        pairing_state_file => File::Spec->catfile( $runtime_dir, 'pairing.json' ),
        live_pane_file => File::Spec->catfile( $runtime_dir, 'live-pane' ),
    };
}

sub legacy_token_listener_paths_for_session {
    my ( $self, $session_id ) = @_;
    my $runtime_root = $self->legacy_token_listener_runtime_root;
    my $runtime_dir = File::Spec->catdir( $runtime_root, $self->normalise_session_id($session_id) );
    return {
        runtime_root => $runtime_root,
        runtime_dir  => $runtime_dir,
        pid_file     => File::Spec->catfile( $runtime_dir, 'listener.pid' ),
        log_file     => File::Spec->catfile( $runtime_dir, 'listener.log' ),
        audit_file   => File::Spec->catfile( $runtime_dir, 'audit.jsonl' ),
        audit_flag_file => File::Spec->catfile( $runtime_dir, 'audit.enabled' ),
        target_session_file => File::Spec->catfile( $runtime_dir, 'claude.session' ),
        transcript_cursor_file => File::Spec->catfile( $runtime_dir, 'transcript.cursor' ),
        pairing_state_file => File::Spec->catfile( $runtime_dir, 'pairing.json' ),
        live_pane_file => File::Spec->catfile( $runtime_dir, 'live-pane' ),
    };
}

sub listener_shared_paths_for_session {
    my ( $self, $session_id ) = @_;
    my $runtime_root = $self->listener_shared_runtime_root;
    return {
        runtime_root   => $runtime_root,
        offset_file    => File::Spec->catfile( $runtime_root, 'listener.offset' ),
        inbox_file     => File::Spec->catfile( $runtime_root, 'listener.inbox.jsonl' ),
        poll_lock_file => File::Spec->catfile( $runtime_root, 'getupdates.pid' ),
        pairing_claim_file => File::Spec->catfile( $runtime_root, 'pairing-claim.json' ),
    };
}

sub legacy_listener_shared_paths_for_session {
    my ( $self, $session_id ) = @_;
    my $runtime_root = $self->legacy_listener_runtime_root;
    return {
        runtime_root   => $runtime_root,
        offset_file    => File::Spec->catfile( $runtime_root, 'listener.offset' ),
        inbox_file     => File::Spec->catfile( $runtime_root, 'listener.inbox.jsonl' ),
        poll_lock_file => File::Spec->catfile( $runtime_root, 'getupdates.pid' ),
        pairing_claim_file => File::Spec->catfile( $runtime_root, 'pairing-claim.json' ),
    };
}

sub legacy_token_listener_shared_paths_for_session {
    my ( $self, $session_id ) = @_;
    my $runtime_root = $self->legacy_token_listener_runtime_root;
    return {
        runtime_root   => $runtime_root,
        offset_file    => File::Spec->catfile( $runtime_root, 'listener.offset' ),
        inbox_file     => File::Spec->catfile( $runtime_root, 'listener.inbox.jsonl' ),
        poll_lock_file => File::Spec->catfile( $runtime_root, 'getupdates.pid' ),
        pairing_claim_file => File::Spec->catfile( $runtime_root, 'pairing-claim.json' ),
    };
}

sub ensure_listener_runtime_migrated {
    my ( $self, $session_id ) = @_;
    my $paths = $self->listener_paths_for_session($session_id);
    my $shared_paths = $self->listener_shared_paths_for_session($session_id);
    my $legacy_flat_shared_paths = $self->legacy_listener_shared_paths_for_session($session_id);
    my $legacy_token_shared_paths = $self->legacy_token_listener_shared_paths_for_session($session_id);
    my $migrated = 0;

    my @legacy_path_sets = (
        $self->legacy_listener_paths_for_session($session_id),
        $self->legacy_token_listener_paths_for_session($session_id),
    );

    for my $legacy_paths (@legacy_path_sets) {
        next if $paths->{runtime_dir} eq $legacy_paths->{runtime_dir};
        for my $field (qw(target_session_file transcript_cursor_file pairing_state_file audit_flag_file audit_file live_pane_file)) {
            $migrated += $self->migrate_listener_runtime_file( $legacy_paths->{$field}, $paths->{$field} );
        }
    }

    if ( $shared_paths->{runtime_root} ne $legacy_token_shared_paths->{runtime_root} ) {
        for my $field (qw(offset_file inbox_file pairing_claim_file)) {
            $migrated += $self->migrate_listener_runtime_file( $legacy_token_shared_paths->{$field}, $shared_paths->{$field} );
        }
    }

    $migrated += $self->scrub_legacy_flat_shared_poll_state(
        legacy_flat_shared_paths  => $legacy_flat_shared_paths,
        legacy_token_shared_paths => $legacy_token_shared_paths,
        shared_paths              => $shared_paths,
    );
    return $migrated ? 1 : 0;
}

sub migrate_listener_runtime_file {
    my ( $self, $source, $target ) = @_;
    return 0 if !defined $source || !defined $target;
    return 0 if $source eq $target;
    return 0 if !-f $source || -f $target;
    make_path( dirname($target) ) if !-d dirname($target);
    return $self->write_text_file( $target, $self->read_text_file($source) ) ? 1 : 0;
}

sub scrub_legacy_flat_shared_poll_state {
    my ( $self, %args ) = @_;
    my $legacy_flat_shared_paths  = $args{legacy_flat_shared_paths}  || {};
    my $legacy_token_shared_paths = $args{legacy_token_shared_paths} || {};
    my $shared_paths              = $args{shared_paths}              || {};
    my $scrubbed = 0;

    for my $field (qw(offset_file inbox_file pairing_claim_file)) {
        my $target = $shared_paths->{$field};
        my $flat   = $legacy_flat_shared_paths->{$field};
        my $token  = $legacy_token_shared_paths->{$field};
        next if !defined $target || !defined $flat;
        next if !-f $target || !-f $flat;
        next if !$self->listener_runtime_files_match( $target, $flat );
        if ( -f $token && !$self->listener_runtime_files_match( $token, $flat ) ) {
            $scrubbed += $self->migrate_listener_runtime_file( $token, $target ) if !-f $target;
            $scrubbed += $self->write_text_file( $target, $self->read_text_file($token) ) ? 1 : 0;
            next;
        }
        unlink $target or die "Unable to remove $target: $!";
        $scrubbed++;
    }

    return $scrubbed ? 1 : 0;
}

sub listener_runtime_files_match {
    my ( $self, $left, $right ) = @_;
    return 0 if !defined $left || !defined $right;
    return 0 if !-f $left || !-f $right;
    return $self->read_text_file($left) eq $self->read_text_file($right) ? 1 : 0;
}

sub read_listener_pairing_claim {
    my ( $self, $shared_paths ) = @_;
    $shared_paths ||= $self->listener_shared_paths_for_session( $self->listener_session_id );
    my $claim = $self->read_json_file_or_default( $shared_paths->{pairing_claim_file}, {} );
    $claim = {} if ref($claim) ne 'HASH';
    return $claim;
}

sub write_listener_pairing_claim {
    my ( $self, $shared_paths, $claim ) = @_;
    $shared_paths ||= $self->listener_shared_paths_for_session( $self->listener_session_id );
    $claim ||= {};
    return $self->write_text_file( $shared_paths->{pairing_claim_file}, $self->encode_pretty_json($claim) );
}

sub read_listener_pairing_state {
    my ( $self, $paths ) = @_;
    $paths ||= $self->listener_paths;
    my $state = $self->read_json_file_or_default( $paths->{pairing_state_file}, {} );
    $state = {} if ref($state) ne 'HASH';
    return $state;
}

sub write_listener_pairing_state {
    my ( $self, $paths, $state ) = @_;
    $paths ||= $self->listener_paths;
    $state ||= {};
    return $self->write_text_file( $paths->{pairing_state_file}, $self->encode_pretty_json($state) );
}

sub generate_listener_pairing_code {
    my ($self) = @_;
    return join q{}, map { sprintf '%02x', int( rand 256 ) } 1 .. 8;
}

sub listener_pairing_command_text {
    my ( $self, $code ) = @_;
    return 'd2 telegram-claude.pair ' . $code;
}

sub listener_pairing_action {
    my ( $self, $summary, $paths ) = @_;
    $paths ||= $self->listener_paths;
    my $pairing_disabled = $self->env_value('TELEGRAM_CLAUDE_DISABLE_PAIRING') || q{};
    if ( $pairing_disabled =~ /\A(?:1|true|yes|on)\z/i ) {
        $self->append_listener_audit_event(
            $paths,
            'pairing.allowed',
            {
                reason  => 'disabled',
                chat_id => defined $summary->{chat} ? $summary->{chat}{id} : undef,
            },
        );
        return { allow => 1 };
    }
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : undef;
    if ( !defined $chat_id ) {
        $self->append_listener_audit_event(
            $paths,
            'pairing.allowed',
            {
                reason => 'missing-chat-id',
            },
        );
        return { allow => 1 };
    }
    my $state = $self->read_listener_pairing_state($paths);
    if ( defined $state->{paired_chat_id} && $state->{paired_chat_id} ne q{} ) {
        if ( $chat_id == $state->{paired_chat_id} ) {
            $self->append_listener_audit_event(
                $paths,
                'pairing.allowed',
                {
                    chat_id => $chat_id,
                    reason  => 'paired-chat',
                },
            );
            return { allow => 1 };
        }
        $self->append_listener_audit_event(
            $paths,
            'pairing.ignored',
            {
                chat_id => $chat_id,
                reason  => 'different-chat',
            },
        );
        return { allow => 0 };
    }
    if ( defined $state->{pending_chat_id} && $state->{pending_chat_id} ne q{} ) {
        if ( $chat_id == $state->{pending_chat_id} ) {
            $self->append_listener_audit_event(
                $paths,
                'pairing.ignored',
                {
                    chat_id => $chat_id,
                    reason  => 'pending-pair',
                },
            );
            return { allow => 0 };
        }
        $self->append_listener_audit_event(
            $paths,
            'pairing.ignored',
            {
                chat_id => $chat_id,
                reason  => 'pending-other-chat',
            },
        );
        return { allow => 0 };
    }
    my $code = $self->generate_listener_pairing_code;
    my $session_id = File::Basename::basename( $paths->{runtime_dir} );
    $state->{pending_chat_id} = $chat_id;
    $state->{pairing_code} = $code;
    $state->{challenge_sent_at} = $self->now_string;
    $self->write_listener_pairing_state( $paths, $state );
    my $shared_paths = $self->listener_shared_paths_for_session($session_id);
    my $claim = $self->read_listener_pairing_claim($shared_paths);
    if ( defined $claim->{session_id} && $claim->{session_id} eq $session_id ) {
        $self->write_listener_pairing_claim( $shared_paths, {} );
    }
    $self->append_listener_audit_event(
        $paths,
        'pairing.challenge.sent',
        {
            chat_id => $chat_id,
        },
    );
    return {
        allow         => 0,
        reply_message => $self->listener_pairing_command_text($code),
    };
}

sub enforce_unique_listener_pairing {
    my ( $self, $session_id, $paths ) = @_;
    $paths ||= $self->listener_paths_for_session($session_id);
    my $state = $self->read_listener_pairing_state($paths);
    my $chat_id = $state->{paired_chat_id};
    return () if !defined $chat_id || $chat_id eq q{};
    my @cleared;
    for my $pairing_file ( glob File::Spec->catfile( $paths->{runtime_root}, '*', 'pairing.json' ) ) {
        my $other_dir = dirname($pairing_file);
        my $other_session_id = File::Basename::basename($other_dir);
        next if $other_session_id eq $self->normalise_session_id($session_id);
        my $other_paths = $self->listener_paths_for_session($other_session_id);
        my $other_state = $self->read_listener_pairing_state($other_paths);
        next if !defined $other_state->{paired_chat_id} || $other_state->{paired_chat_id} ne $chat_id;
        delete $other_state->{paired_chat_id};
        delete $other_state->{paired_at};
        $self->write_listener_pairing_state( $other_paths, $other_state );
        push @cleared, $other_session_id;
        $self->append_listener_audit_event(
            $other_paths,
            'pairing.unpaired_by_other_session',
            {
                chat_id             => $chat_id,
                replacement_session => $session_id,
            },
        );
    }
    return @cleared;
}

sub listener_audit_enabled {
    my ( $self, $paths ) = @_;
    $paths ||= $self->listener_paths;
    return 1 if ( $self->env_value('TELEGRAM_CLAUDE_AUDIT') || q{} ) =~ /\A(?:1|true|yes|on)\z/i;
    return 1 if defined $paths->{audit_flag_file} && -f $paths->{audit_flag_file};
    return 0;
}

sub set_listener_audit_enabled {
    my ( $self, $session_id, $enabled ) = @_;
    return if !defined $session_id || $session_id eq q{};
    my $paths = $self->listener_paths_for_session($session_id);
    make_path( $paths->{runtime_dir} ) if !-d $paths->{runtime_dir};
    return $self->write_text_file( $paths->{audit_flag_file}, "1\n" ) if $enabled;
    return 1;
}

sub append_listener_audit_event {
    my ( $self, $paths, $type, $payload ) = @_;
    return 1 if !$self->listener_audit_enabled($paths);
    my %row = (
        ts   => $self->now_string,
        type => $type,
        %{ $payload || {} },
    );
    my $path = $paths->{audit_file};
    make_path( dirname($path) ) if !-d dirname($path);
    open my $fh, '>>', $path or return 0;
    print {$fh} encode_json( \%row ) . "\n";
    close $fh;
    return 1;
}

sub listener_session_id {
    my ($self) = @_;
    my $session_id = $self->env_value('TELEGRAM_CLAUDE_SESSION_ID');
    $session_id = $self->env_value('CLAUDE_SESSION_ID') if !defined $session_id || $session_id eq q{};
    $session_id = $self->workspace_session_id if !defined $session_id || $session_id eq q{};
    return $self->normalise_session_id($session_id);
}

sub with_listener_session_context {
    my ( $self, $session_id, $code ) = @_;
    local $self->{env}{TELEGRAM_CLAUDE_SESSION_ID} = $session_id;
    local $ENV{TELEGRAM_CLAUDE_SESSION_ID} = $session_id;
    return $code->();
}

sub normalise_session_id {
    my ( $self, $session_id ) = @_;
    $session_id = 'default' if !defined $session_id || $session_id eq q{};
    $session_id =~ s{[^A-Za-z0-9_.-]+}{-}g;
    $session_id =~ s{\A-+}{};
    $session_id =~ s{-+\z}{};
    return $session_id eq q{} ? 'default' : $session_id;
}

sub read_listener_offset {
    my ( $self, $path ) = @_;
    return undef if !-f $path;
    my $content = $self->read_text_file($path);
    $content =~ s/\s+\z//;
    return undef if $content eq q{};
    return 0 + $content;
}

sub write_listener_offset {
    my ( $self, $path, $offset ) = @_;
    return $self->write_text_file( $path, $offset . "\n" );
}

sub recover_listener_offset_from_inbox {
    my ( $self, $path ) = @_;
    return undef if !-f $path;
    my @lines = grep { defined $_ && $_ ne q{} } split /\n/, $self->read_text_file($path);
    for my $line ( reverse @lines ) {
        my $decoded = eval { decode_json($line) };
        next if $@ || ref($decoded) ne 'HASH';
        next if !defined $decoded->{update_id};
        return $decoded->{update_id} + 1;
    }
    return undef;
}

sub inbox_contains_update_id {
    my ( $self, $path, $target_update_id ) = @_;
    return 0 if !defined $target_update_id || !-f $path;
    my @lines = grep { defined $_ && $_ ne q{} } split /\n/, $self->read_text_file($path);
    for my $line ( reverse @lines ) {
        my $decoded = eval { decode_json($line) };
        next if $@ || ref($decoded) ne 'HASH';
        next if !defined $decoded->{update_id};
        return 1 if $decoded->{update_id} == $target_update_id;
    }
    return 0;
}

sub listener_reply_mode_for_update {
    my ( $self, $reply_text ) = @_;
    my $mode = $self->env_value('TELEGRAM_CLAUDE_LISTENER_MODE');
    if ( ( !defined $mode || $mode eq q{} ) && ( !defined $reply_text || $reply_text eq q{} ) ) {
        $mode = 'claude-session'
          if defined $self->read_claude_target_session_id( $self->listener_paths->{target_session_file} );
    }
    $mode ||= 'static';
    return $mode;
}

sub listener_slash_command_name {
    my ( $self, $summary ) = @_;
    my $text = defined $summary->{text} ? $summary->{text} : q{};
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    return undef if $text !~ m{\A/([A-Za-z0-9_]+)(?:@[A-Za-z0-9_]+)?(?:\s+.*)?\z};
    return lc $1;
}

sub listener_slash_command_reply {
    my ( $self, $summary, $paths ) = @_;
    my $command = $self->listener_slash_command_name($summary);
    return undef if !defined $command;
    $paths ||= $self->listener_paths;
    return $self->listener_status_reply($paths)
      if $command eq 'status';
    return $self->listener_help_reply
      if $command eq 'help';
    return "Unsupported Telegram slash command: /$command\nSupported commands:\n/help\n/status";
}

sub listener_help_reply {
    my ($self) = @_;
    return join(
        "\n",
        'Supported Telegram slash commands:',
        '/help',
        '/status',
    );
}

sub listener_status_reply {
    my ( $self, $paths ) = @_;
    $paths ||= $self->listener_paths;
    my $claude_session_id = $self->resolve_claude_reply_session_id;
    for my $live_pane ( $self->listener_status_live_pane_candidates( $claude_session_id, $paths ) ) {
        my $visible_status = eval { $self->claude_live_status_snapshot( $claude_session_id, $live_pane ) };
        if ( defined $visible_status && $visible_status ne q{} && !$@ ) {
            $self->write_listener_live_pane_id( $paths, $live_pane );
            return $visible_status;
        }
        my $live_status = eval { $self->claude_live_status_reply( $claude_session_id, $live_pane ) };
        if ( defined $live_status && $live_status ne q{} && !$@ ) {
            $self->write_listener_live_pane_id( $paths, $live_pane );
            return $live_status;
        }
    }
    return join(
        "\n",
        'Claude /status unavailable.',
        "No live tmux-backed Claude TUI pane is attached for session: $claude_session_id",
        'Open that same session in tmux and run /status again.',
    );
}

sub claude_live_status_snapshot {
    my ( $self, $session_id, $pane_id ) = @_;
    die "Missing Claude session id for live /status\n" if !defined $session_id || $session_id eq q{};
    die "Missing tmux pane id for live /status\n" if !defined $pane_id || $pane_id eq q{};
    my $capture = $self->tmux_capture_pane_text($pane_id);
    my $block = $self->extract_claude_status_block($capture);
    return undef if !defined $block || $block eq q{};
    return undef if $block !~ /Session:\s+\Q$session_id\E\b/m;
    return $block;
}

sub claude_live_status_reply {
    my ( $self, $session_id, $pane_id ) = @_;
    die "Missing Claude session id for live /status\n" if !defined $session_id || $session_id eq q{};
    die "Missing tmux pane id for live /status\n" if !defined $pane_id || $pane_id eq q{};
    my $before = $self->tmux_capture_pane_text($pane_id);
    $self->tmux_send_text_to_pane( $pane_id, '/status' );
    my $baseline_block = $self->extract_claude_status_block($before);
    for ( 1 .. 50 ) {
        my $capture = $self->tmux_capture_pane_text($pane_id);
        my $block = $self->extract_claude_status_block($capture);
        if (
            defined $block
            && $block ne q{}
            && (
                !defined $baseline_block
                || $block ne $baseline_block
                || $capture ne $before
            )
          )
        {
            return $block;
        }
        $self->listener_pause_seconds(0.1);
    }
    die "Unable to capture live Claude /status output from tmux pane $pane_id\n";
}

sub extract_claude_status_block {
    my ( $self, $capture ) = @_;
    return undef if !defined $capture || $capture eq q{};
    my @lines = split /\n/, $capture;
    my $anchor = -1;
    for my $index ( 0 .. $#lines ) {
        next if $lines[$index] !~ /Session:/;
        $anchor = $index;
    }
    return undef if $anchor < 0;
    my $start = $anchor;
    $start-- while $start > 0 && $self->claude_status_block_line( $lines[ $start - 1 ] );
    my $end = $anchor;
    $end++ while $end < $#lines && $self->claude_status_block_line( $lines[ $end + 1 ] );
    my @block = @lines[ $start .. $end ];
    shift @block while @block && $block[0] =~ /\A\s*\z/;
    pop @block while @block && $block[-1] =~ /\A\s*\z/;
    return undef if !@block;
    return join "\n", @block;
}

sub claude_status_block_line {
    my ( $self, $line ) = @_;
    return 0 if !defined $line;
    return 1 if $line =~ /\A\s*\z/;
    return 1 if $line =~ /(?:Model:|Directory:|Permissions:|Agents\.md:|Account:|Collaboration mode:|Session:|Context window:|limit:|resets\b)/;
    return 1 if $line !~ /[[:alnum:]]/;
    return 0;
}

sub listener_status_live_pane_candidates {
    my ( $self, $session_id, $paths ) = @_;
    $paths ||= $self->listener_paths;
    my %seen;
    my @pane_ids;
    my $cached = $self->read_listener_live_pane_id($paths);
    if ( defined $cached && $cached ne q{} && $self->tmux_pane_id_exists($cached) ) {
        push @pane_ids, $cached;
        $seen{$cached} = 1;
    }
    for my $pane_id ( $self->resolve_claude_live_tmux_panes($session_id) ) {
        next if !defined $pane_id || $pane_id eq q{};
        next if $seen{$pane_id}++;
        push @pane_ids, $pane_id;
    }
    return @pane_ids;
}

sub read_listener_live_pane_id {
    my ( $self, $paths ) = @_;
    $paths ||= $self->listener_paths;
    return undef if !defined $paths->{live_pane_file} || !-f $paths->{live_pane_file};
    my $content = $self->read_text_file( $paths->{live_pane_file} );
    $content =~ s/\s+\z// if defined $content;
    return !defined $content || $content eq q{} ? undef : $content;
}

sub write_listener_live_pane_id {
    my ( $self, $paths, $pane_id ) = @_;
    $paths ||= $self->listener_paths;
    return 1 if !defined $pane_id || $pane_id eq q{};
    make_path( $paths->{runtime_dir} ) if defined $paths->{runtime_dir} && !-d $paths->{runtime_dir};
    return $self->write_text_file( $paths->{live_pane_file}, $pane_id . "\n" );
}

sub listener_should_send_typing {
    my ( $self, $summary, $mode ) = @_;
    return 0 if !defined $mode || $mode ne 'claude-session';
    return 0 if !defined $summary->{chat} || !defined $summary->{chat}{id};
    return 0 if !$self->update_needs_listener_reply($summary);
    return 1;
}

sub listener_reply_message_for_update {
    my ( $self, $summary, $reply_text, $mode, %args ) = @_;
    $mode = $self->listener_reply_mode_for_update($reply_text) if !defined $mode || $mode eq q{};
    return $self->claude_session_reply_for_update( $summary, %args ) if $mode eq 'claude-session';
    return $reply_text;
}

sub listener_chat_is_paired_for_claude_session {
    my ( $self, $summary, $paths ) = @_;
    $paths ||= $self->listener_paths;
    my $pairing_disabled = $self->env_value('TELEGRAM_CLAUDE_DISABLE_PAIRING') || q{};
    return 1 if $pairing_disabled =~ /\A(?:1|true|yes|on)\z/i;
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : undef;
    return 0 if !defined $chat_id;
    my $state = $self->read_listener_pairing_state($paths);
    return 0 if !defined $state->{paired_chat_id} || $state->{paired_chat_id} eq q{};
    return $chat_id == $state->{paired_chat_id} ? 1 : 0;
}

sub claude_session_reply_for_update {
    my ( $self, $summary, %args ) = @_;
    my $paths = $self->listener_paths;
    if ( !$self->listener_chat_is_paired_for_claude_session( $summary, $paths ) ) {
        $self->append_listener_audit_event(
            $paths,
            'pairing.reply_path_blocked',
            {
                chat_id    => defined $summary->{chat} ? $summary->{chat}{id} : undef,
                message_id => $summary->{message_id},
            },
        );
        return undef;
    }
    my $session_id = $self->resolve_claude_reply_session_id;
    my $live_pane = $self->resolve_claude_live_tmux_pane($session_id);
    if ( defined $live_pane && $live_pane ne q{} ) {
        $self->write_listener_live_pane_id( $paths, $live_pane );
        my $reply = eval {
            return $self->run_claude_session_live_pane(
                $session_id,
                $live_pane,
                $summary,
                %args,
            );
        };
        if ( defined $reply && !$@ ) {
            return $reply;
        }
        my $error = $@;
        chomp $error;
        $error ||= 'Live Claude pane reply failed';
        $self->append_listener_audit_event(
            $paths,
            'claude.live_pane.fallback',
            {
                session_id => $session_id,
                pane_id    => $live_pane,
                error      => $error,
            },
        );
    }
    my $prompt = $self->claude_session_reply_prompt($summary);
    my $needs_completion = $self->telegram_message_requires_completion($summary);
    my $reply = $self->run_claude_session_resume( $session_id, $prompt, $summary, %args );
    if ( $needs_completion && $self->telegram_reply_is_promise_placeholder($reply) ) {
        $reply = $self->run_claude_session_resume(
            $session_id,
            $self->claude_session_retry_prompt( $summary, $reply ),
            $summary,
            %args,
        );
    }
    $self->sync_telegram_exchange_to_claude_session( $session_id, $summary, $reply );
    return $reply;
}

sub run_claude_session_live_pane {
    my ( $self, $session_id, $pane_id, $summary, %args ) = @_;
    my $on_progress = $args{on_progress};
    my $paths = $self->listener_paths;
    my $transcript_path = $self->claude_session_transcript_path($session_id)
      or die "Unable to locate the live Claude transcript for session $session_id\n";
    my $cursor = $self->claude_session_transcript_size($transcript_path);
    my $prompt = $self->claude_live_pane_prompt($summary);
    $self->tmux_send_text_to_pane( $pane_id, $prompt );
    $self->append_listener_audit_event(
        $paths,
        'claude.live_pane.injected',
        {
            session_id      => $session_id,
            pane_id         => $pane_id,
            transcript_path => $transcript_path,
        },
    );

    my $saw_user = 0;
    my $matched_user_text;
    my $user_wait_cycles = 0;
    my %seen_progress;
    for ( 1 .. 600 ) {
        my ( $next_cursor, @events ) = $self->claude_session_transcript_events_since( $transcript_path, $cursor );
        $cursor = $next_cursor;
        for my $event (@events) {
            if ( !$saw_user ) {
                if ( $event->{role} eq 'user' && $self->claude_live_pane_user_event_matches_prompt( $summary, $prompt, $event->{text} ) ) {
                    $saw_user = 1;
                    $matched_user_text = $event->{text};
                    $self->append_listener_audit_event(
                        $paths,
                        'claude.live_pane.user_seen',
                        {
                            session_id => $session_id,
                            pane_id    => $pane_id,
                            user_text  => $matched_user_text,
                        },
                    );
                }
                next;
            }
            next if $event->{role} ne 'assistant';
            if ( ( $event->{phase} || q{} ) eq 'commentary' ) {
                next if !$on_progress;
                for my $line ( grep { defined $_ && $_ ne q{} } split /\n+/, $event->{text} ) {
                    next if $seen_progress{$line}++;
                    my $ok = eval { $on_progress->($line) };
                    if ( !$ok || $@ ) {
                        my $error = $@;
                        chomp $error;
                        $error ||= 'Claude live-pane progress callback failed';
                        $self->append_listener_audit_event(
                            $paths,
                            'claude.live_pane.progress_callback_failed',
                            {
                                session_id => $session_id,
                                pane_id    => $pane_id,
                                error      => $error,
                                line       => $line,
                            },
                        );
                    }
                }
                next;
            }
            if ( ( $event->{phase} || q{} ) eq 'final_answer' ) {
                $self->write_listener_offset( $paths->{transcript_cursor_file}, $cursor );
                $self->append_listener_audit_event(
                    $paths,
                    'claude.live_pane.completed',
                    {
                        session_id  => $session_id,
                        pane_id     => $pane_id,
                        reply_bytes => length( $event->{text} || q{} ),
                    },
                );
                return $event->{text};
            }
        }
        if ( !$saw_user ) {
            $user_wait_cycles++;
            if ( $user_wait_cycles >= 15 ) {
                die "Live Claude pane never recorded the injected Telegram turn\n";
            }
        }
        $self->listener_pause_seconds(1);
    }
    die "Timed out waiting for the live Claude pane to finish the Telegram turn\n";
}

sub run_claude_session_resume {
    my ( $self, $session_id, $prompt, $summary, %args ) = @_;
    my $on_progress = $args{on_progress};
    if ( $self->{claude_resume_runner} ) {
        return $self->{claude_resume_runner}->( $session_id, $prompt, $summary, \%args );
    }
    my $paths = $self->claude_launcher_paths;
    my $real_claude_bin = $self->resolve_real_claude_bin($paths);
    make_path( $self->listener_paths->{runtime_dir} ) if !-d $self->listener_paths->{runtime_dir};
    my ( $stderr_fh, $stderr_file ) = tempfile( 'telegram-claude-stderr-XXXX', DIR => $self->listener_paths->{runtime_dir}, SUFFIX => '.log' );
    close $stderr_fh or die "Unable to close $stderr_file: $!";
    my @image_inputs = $self->claude_session_image_input_paths($summary);
    my $prompt_with_images = @image_inputs
      ? join( "\n", $prompt, map { "telegram_image_local_path=$_ (already downloaded; read this image file with your Read tool)" } @image_inputs )
      : $prompt;
    my @command = (
        $real_claude_bin,
        '-p', $prompt_with_images,
        '--resume', $session_id,
        '--output-format', 'stream-json',
        '--verbose',
        '--dangerously-skip-permissions',
    );
    my $stderr = gensym();
    my $pid = open3( undef, my $json_fh, $stderr, @command );
    my $selector = IO::Select->new( $json_fh, $stderr );
    my @stderr_lines;
    my $reply_from_events;
    while ( my @ready = $selector->can_read ) {
        for my $handle (@ready) {
            my $line = <$handle>;
            if ( !defined $line ) {
                $selector->remove($handle);
                next;
            }
            chomp $line;
            next if !defined $line || $line eq q{};
            if ( fileno($handle) == fileno($json_fh) ) {
                my $event = eval { decode_json($line) };
                if ( !$@ && ref($event) eq 'HASH' ) {
                    if ( ( $event->{type} || q{} ) eq 'result' ) {
                        $reply_from_events = $event->{result} if defined $event->{result};
                    }
                    $self->append_listener_audit_event(
                        $self->listener_paths,
                        'claude.progress.event',
                        {
                            type    => $event->{type},
                            subtype => $event->{subtype},
                        },
                    );
                    next if !$on_progress;
                    my @lines = $self->claude_progress_lines_for_event($event);
                    for my $progress_line (@lines) {
                        my $ok = eval { $on_progress->($progress_line) };
                        if ( !$ok || $@ ) {
                            my $error = $@;
                            chomp $error;
                            $error ||= 'Claude progress callback failed';
                            $self->append_listener_audit_event(
                                $self->listener_paths,
                                'claude.progress.callback_failed',
                                {
                                    error => $error,
                                    line  => $progress_line,
                                },
                            );
                        }
                    }
                    next;
                }
            }
            push @stderr_lines, $line;
        }
    }
    waitpid( $pid, 0 );
    my $exit = $?;
    $self->write_text_file( $stderr_file, join( "\n", @stderr_lines ) . ( @stderr_lines ? "\n" : q{} ) );
    my $reply = defined $reply_from_events ? $reply_from_events : q{};
    $reply =~ s/\A\s+//;
    $reply =~ s/\s+\z//;
    my $stderr_tail = join "\n", @stderr_lines[ @stderr_lines > 12 ? $#stderr_lines - 11 : 0 .. $#stderr_lines ];
    $stderr_tail =~ s/\s+\z// if defined $stderr_tail;
    $self->append_listener_audit_event(
        $self->listener_paths,
        'claude.resume.completed',
        {
            session_id  => $session_id,
            exit_code   => $exit == -1 ? -1 : ( $exit >> 8 ),
            signal      => $exit == -1 ? undef : ( $exit & 127 ),
            reply_bytes => length($reply),
            stderr_tail => $stderr_tail,
            stderr_file => $stderr_file,
        },
    );
    my $exit_code = $exit == -1 ? -1 : ( $exit >> 8 );
    my $signal = $exit == -1 ? 0 : ( $exit & 127 );
    if ( $exit == -1 || $exit_code != 0 || $signal != 0 || $reply eq q{} ) {
        my $message = $reply eq q{}
          ? 'Claude resume returned an empty Telegram reply'
          : 'Claude resume failed for Telegram reply';
        $message .= sprintf ' (exit=%s signal=%s)', $exit_code, $signal;
        $message .= "\nStderr tail:\n$stderr_tail" if defined $stderr_tail && $stderr_tail ne q{};
        unlink $stderr_file if -f $stderr_file;
        die "$message\n";
    }
    unlink $stderr_file if -f $stderr_file;
    return $reply;
}

sub resolve_claude_reply_session_id {
    my ($self) = @_;
    return $self->env_value('TELEGRAM_CLAUDE_TARGET_SESSION_ID')
      || $self->read_claude_target_session_id( $self->listener_paths->{target_session_file} )
      || $self->mapped_claude_session_from_config
      || $self->listener_session_id;
}

sub resolve_claude_live_tmux_pane {
    my ( $self, $session_id ) = @_;
    my @pane_ids = $self->resolve_claude_live_tmux_panes($session_id);
    return !@pane_ids ? undef : $pane_ids[0];
}

sub resolve_claude_live_tmux_panes {
    my ( $self, $session_id ) = @_;
    my @matches = $self->best_claude_live_tmux_matches($session_id);
    return map { $_->{pane_id} } @matches;
}

sub discover_claude_session_tty {
    my ( $self, $session_id ) = @_;
    my $match = $self->best_claude_live_tmux_match($session_id);
    return !$match ? undef : $match->{tty};
}

sub best_claude_live_tmux_match {
    my ( $self, $session_id ) = @_;
    my @matches = $self->best_claude_live_tmux_matches($session_id);
    return !@matches ? undef : $matches[0];
}

sub best_claude_live_tmux_matches {
    my ( $self, $session_id ) = @_;
    return () if !defined $session_id || $session_id eq q{};
    my @rows = sort {
        ( $a->{etimes} // 1_000_000_000 ) <=> ( $b->{etimes} // 1_000_000_000 )
          || $b->{pid} <=> $a->{pid}
    } $self->claude_process_rows;
    my %seen_panes;
    my @matches;
    for my $row (@rows) {
        next if !$row->{cmd} || $row->{cmd} !~ /\bclaude\b/;
        next if $row->{cmd} !~ /\bresume\s+\Q$session_id\E(?:\s|\z)/;
        next if !$row->{tty} || $row->{tty} eq '?';
        my $pane_id = $self->discover_tmux_pane_for_tty( $row->{tty} );
        next if !defined $pane_id || $pane_id eq q{};
        next if $seen_panes{$pane_id}++;
        push @matches, {
            pid     => $row->{pid},
            tty     => $row->{tty},
            pane_id => $pane_id,
            etimes  => $row->{etimes},
            cmd     => $row->{cmd},
        };
    }
    return @matches;
}

sub claude_process_rows {
    my ($self) = @_;
    if ( $self->{process_list_runner} ) {
        return @{ $self->{process_list_runner}->() || [] };
    }
    open my $fh, '-|', 'ps', '-eo', 'pid=,ppid=,tty=,etimes=,args='
      or die "Unable to run ps for claude process discovery: $!";
    my @rows;
    while ( my $line = <$fh> ) {
        chomp $line;
        next if !defined $line || $line eq q{};
        my ( $pid, $ppid, $tty, $etimes, $cmd ) = $line =~ /\A\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(.*)\z/;
        next if !defined $pid;
        push @rows, {
            pid => 0 + $pid,
            ppid => defined $ppid ? 0 + $ppid : undef,
            tty => $tty,
            etimes => defined $etimes ? 0 + $etimes : undef,
            cmd => $cmd,
        };
    }
    close $fh;
    return @rows;
}

sub discover_tmux_pane_for_tty {
    my ( $self, $tty ) = @_;
    return undef if !defined $tty || $tty eq q{};
    my @panes = $self->tmux_pane_rows;
    my $wanted_tty = $tty =~ m{\A/dev/} ? $tty : '/dev/' . $tty;
    for my $pane (@panes) {
        next if !$pane->{tty};
        return $pane->{pane_id} if $pane->{tty} eq $wanted_tty;
    }
    return undef;
}

sub tmux_pane_rows {
    my ($self) = @_;
    if ( $self->{tmux_panes_runner} ) {
        return @{ $self->{tmux_panes_runner}->() || [] };
    }
    open my $fh, '-|', 'tmux', 'list-panes', '-a', '-F', '#{pane_id}' . "\t" . '#{pane_tty}' . "\t" . '#{pane_current_command}'
      or return ();
    my @rows;
    while ( my $line = <$fh> ) {
        chomp $line;
        my ( $pane_id, $tty, $current_command ) = split /\t/, $line, 3;
        next if !defined $pane_id || !defined $tty;
        push @rows, {
            pane_id         => $pane_id,
            tty             => $tty,
            current_command => $current_command,
        };
    }
    close $fh;
    return @rows;
}

sub tmux_pane_id_exists {
    my ( $self, $pane_id ) = @_;
    return 0 if !defined $pane_id || $pane_id eq q{};
    for my $pane ( $self->tmux_pane_rows ) {
        next if !defined $pane->{pane_id};
        return 1 if $pane->{pane_id} eq $pane_id;
    }
    return 0;
}

sub tmux_send_text_to_pane {
    my ( $self, $pane_id, $text ) = @_;
    die "Missing tmux pane id\n" if !defined $pane_id || $pane_id eq q{};
    $text = q{} if !defined $text;
    if ( $self->{tmux_send_runner} ) {
        return $self->{tmux_send_runner}->( $pane_id, $text );
    }
    system( 'tmux', 'send-keys', '-t', $pane_id, '-l', '--', $text ) == 0
      or die "Unable to send literal text to tmux pane $pane_id\n";
    system( 'tmux', 'send-keys', '-t', $pane_id, 'C-j' ) == 0
      or die "Unable to submit injected text to tmux pane $pane_id\n";
    return 1;
}

sub tmux_capture_pane_text {
    my ( $self, $pane_id ) = @_;
    die "Missing tmux pane id\n" if !defined $pane_id || $pane_id eq q{};
    if ( $self->{tmux_capture_runner} ) {
        return $self->{tmux_capture_runner}->($pane_id);
    }
    open my $fh, '-|', 'tmux', 'capture-pane', '-p', '-t', $pane_id or die "Unable to capture tmux pane $pane_id\n";
    local $/ = undef;
    my $content = <$fh>;
    close $fh;
    return defined $content ? $content : q{};
}

sub claude_live_pane_prompt {
    my ( $self, $summary ) = @_;
    my @lines;
    push @lines, $summary->{text} if defined $summary->{text} && $summary->{text} ne q{};
    push @lines, '[caption] ' . $summary->{caption} if defined $summary->{caption} && $summary->{caption} ne q{};
    my @media = $self->telegram_session_media_summary_lines($summary);
    if (@media) {
        push @lines, 'Any *_local_path values below are already downloaded locally for this active Claude session.';
        push @lines, @media;
    }
    return join "\n", @lines;
}

sub claude_live_pane_user_event_matches_prompt {
    my ( $self, $summary, $prompt, $event_text ) = @_;
    return 0 if !defined $event_text || $event_text eq q{};
    return 1 if $event_text eq $prompt;
    my $normalized_prompt = $prompt;
    my $normalized_event  = $event_text;
    $normalized_prompt =~ s/\s+/ /g;
    $normalized_prompt =~ s/\A\s+//;
    $normalized_prompt =~ s/\s+\z//;
    $normalized_event =~ s/\s+/ /g;
    $normalized_event =~ s/\A\s+//;
    $normalized_event =~ s/\s+\z//;
    return 1 if $normalized_event eq $normalized_prompt;
    my $text = defined $summary->{text} ? $summary->{text} : q{};
    my $caption = defined $summary->{caption} ? $summary->{caption} : q{};
    return 1 if $text ne q{} && index( $normalized_event, $text ) >= 0;
    return 1 if $caption ne q{} && index( $normalized_event, $caption ) >= 0;
    return 0;
}

sub claude_session_transcript_size {
    my ( $self, $path ) = @_;
    return 0 if !defined $path || !-f $path;
    return -s $path;
}

sub claude_session_transcript_events_since {
    my ( $self, $path, $offset ) = @_;
    return ( 0 ) if !defined $path || !-f $path;
    $offset = 0 if !defined $offset;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    seek $fh, $offset, 0 or die "Unable to seek $path: $!";
    my @events;
    while ( my $line = <$fh> ) {
        my $decoded = eval { decode_json($line) };
        next if $@ || ref($decoded) ne 'HASH';
        my $event = $self->claude_session_transcript_event_from_record($decoded);
        push @events, $event if $event;
    }
    my $next_offset = tell($fh);
    close $fh;
    return ( $next_offset, @events );
}

sub claude_session_transcript_event_from_record {
    my ( $self, $row ) = @_;
    return undef if !$row || ref($row) ne 'HASH';
    my $type = $row->{type} || q{};
    return undef if $type ne 'user' && $type ne 'assistant';
    my $message = $row->{message} || {};
    return undef if ref($message) ne 'HASH';
    my $role = $message->{role} || $type;
    return undef if $role ne 'user' && $role ne 'assistant';
    my $text = $self->claude_session_message_text_from_payload($message);
    return undef if !defined $text || $text eq q{};
    return {
        role  => $role,
        text  => $text,
        phase => $row->{phase},
    };
}

sub process_tui_live_outbound_transcript {
    my ( $self, $session_id, $paths, $state, %args ) = @_;
    return 0 if !defined $session_id || $session_id eq q{};
    my $pairing = $self->read_listener_pairing_state($paths);
    my $chat_id = $pairing->{paired_chat_id};
    return 0 if !defined $chat_id || $chat_id eq q{};
    my $transcript = $self->claude_session_transcript_path( $self->resolve_claude_reply_session_id );
    return 0 if !defined $transcript || !-f $transcript;
    my $cursor = $self->read_listener_offset( $paths->{transcript_cursor_file} );
    if ( !defined $cursor ) {
        $cursor = $self->claude_session_transcript_size($transcript);
        $self->write_listener_offset( $paths->{transcript_cursor_file}, $cursor );
        return 0;
    }
    my ( $next_cursor, @events ) = $self->claude_session_transcript_events_since( $transcript, $cursor );
    $cursor = $next_cursor;
    for my $event (@events) {
        if ( !$state->{active} ) {
            next if $event->{role} ne 'user';
            next if $event->{text} =~ /\A\[Telegram chat /;
            my $reporter = $self->start_telegram_verbose_reporter(
                chat_id => $chat_id,
                on_error => sub {
                    my ($error) = @_;
                    push @{ $args{progress_errors} || [] }, { chat_id => $chat_id, error => $error };
                    return 1;
                },
            );
            my $typing_error = $self->send_telegram_typing_action_for_chat($chat_id);
            my $typing_guard = $self->start_listener_typing_guard(
                {
                    chat => { id => $chat_id },
                    text => $event->{text},
                }
            );
            $state->{active} = {
                chat_id       => $chat_id,
                reporter      => $reporter,
                seen_progress => {},
                typing_guard  => $typing_guard,
            };
            eval { $reporter->{emit}->('Resuming active Claude session') } if $reporter;
            next;
        }
        next if $event->{role} ne 'assistant';
        my $reporter = $state->{active}{reporter};
        if ( ( $event->{phase} || q{} ) eq 'commentary' ) {
            for my $line ( grep { defined $_ && $_ ne q{} } split /\n+/, $event->{text} ) {
                next if $state->{active}{seen_progress}{$line}++;
                eval { $reporter->{emit}->($line) } if $reporter;
            }
            next;
        }
        if ( ( $event->{phase} || q{} ) eq 'final_answer' ) {
            $self->dispatch_listener_reply(
                chat_id       => $chat_id,
                reply_message => $event->{text},
            );
            eval { $reporter->{finish}->() } if $reporter;
            if ( my $typing_guard = $state->{active}{typing_guard} ) {
                eval { $typing_guard->() };
            }
            $state->{active} = undef;
        }
    }
    $self->write_listener_offset( $paths->{transcript_cursor_file}, $cursor );
    return scalar @events;
}

sub with_listener_typing_status {
    my ( $self, $summary, %args ) = @_;
    my $typing_errors = $args{typing_errors} || [];
    my $code = $args{code};
    my $guard;
    if ( $self->listener_should_send_typing( $summary, 'claude-session' ) ) {
        my $error = $self->send_listener_typing_action($summary);
        push @{$typing_errors}, $error if $error;
        $guard = $self->start_listener_typing_guard($summary);
    }
    my $wantarray = wantarray;
    my ( @results, $result );
    my $ok = eval {
        if ($wantarray) {
            @results = $code->();
        }
        elsif ( defined $wantarray ) {
            $result = $code->();
        }
        else {
            $code->();
        }
        return 1;
    };
    my $error = $@;
    if ($guard) {
        my $cleanup_ok = eval {
            $guard->();
            return 1;
        };
        die $@ if !$cleanup_ok && !$error;
    }
    die $error if !$ok;
    return $wantarray ? @results : $result;
}

sub start_listener_typing_guard {
    my ( $self, $summary ) = @_;
    return undef if !$self->listener_should_send_typing( $summary, 'claude-session' );
    return $self->{typing_guard_runner}->( $summary, $self ) if $self->{typing_guard_runner};
    my $chat_id = $summary->{chat}{id};
    return undef if !defined $chat_id;
    pipe( my $reader, my $writer ) or return undef;
    my $pid = $self->{fork_runner} ? $self->{fork_runner}->() : fork();
    if ( !defined $pid ) {
        close $reader;
        close $writer;
        return undef;
    }
    if ( !$pid ) {
        close $writer;
        my $interval = $self->listener_typing_interval_seconds;
        while (1) {
            my $rin = q{};
            vec( $rin, fileno($reader), 1 ) = 1;
            my $ready = select( my $rout = $rin, undef, undef, $interval );
            last if $ready;
            eval { $self->send_listener_typing_action($summary) };
        }
        close $reader;
        exit 0;
    }
    close $reader;
    return sub {
        close $writer;
        waitpid( $pid, 0 );
        return 1;
    };
}

sub send_listener_typing_action {
    my ( $self, $summary ) = @_;
    return undef if !$self->listener_should_send_typing( $summary, 'claude-session' );
    my $message_id = $summary->{message_id};
    my $chat_id = $summary->{chat}{id};
    my $error = eval {
        $self->telegram_post(
            'sendChatAction',
            {
                chat_id => $chat_id,
                action  => 'typing',
            }
        );
        return undef;
    };
    if ( my $failure = $@ ) {
        chomp $failure;
        return {
            update_id  => $summary->{update_id},
            chat_id    => $chat_id,
            message_id => $message_id,
            error      => $failure,
        };
    }
    return undef;
}

sub listener_typing_interval_seconds {
    my ($self) = @_;
    return 3;
}

sub start_listener_progress_guard {
    my ( $self, $summary ) = @_;
    return undef if !$self->listener_should_stream_progress($summary);
    return $self->{progress_guard_runner}->( $summary, $self ) if $self->{progress_guard_runner};
    my $chat_id = $summary->{chat}{id};
    my $reply_to_message_id = $summary->{message_id};
    return undef if !defined $chat_id || !defined $reply_to_message_id;
    my $sent = eval {
        $self->telegram_post(
            'sendMessage',
            {
                chat_id             => $chat_id,
                reply_to_message_id => $reply_to_message_id,
                text                => $self->listener_progress_text( start => 0 ),
            }
        );
    };
    return undef if !$sent || !ref($sent) || !$sent->{result}{message_id};
    my $progress_message_id = $sent->{result}{message_id};
    pipe( my $reader, my $writer ) or return $self->listener_noop_guard;
    my $pid = $self->{fork_runner} ? $self->{fork_runner}->() : fork();
    if ( !defined $pid ) {
        close $reader;
        close $writer;
        return $self->listener_noop_guard;
    }
    if ( !$pid ) {
        close $writer;
        my $interval = $self->listener_progress_interval_seconds;
        my $tick = 1;
        while (1) {
            my $rin = q{};
            vec( $rin, fileno($reader), 1 ) = 1;
            my $ready = select( my $rout = $rin, undef, undef, $interval );
            last if $ready;
            eval {
                $self->telegram_post(
                    'editMessageText',
                    {
                        chat_id    => $chat_id,
                        message_id => $progress_message_id,
                        text       => $self->listener_progress_text( continue => $tick++ ),
                    }
                );
            };
        }
        close $reader;
        exit 0;
    }
    close $reader;
    return sub {
        close $writer;
        waitpid( $pid, 0 );
        eval {
            $self->telegram_post(
                'deleteMessage',
                {
                    chat_id    => $chat_id,
                    message_id => $progress_message_id,
                }
            );
        };
        return 1;
    };
}

sub listener_noop_guard {
    my ($self) = @_;
    return sub { return 1; };
}

sub listener_should_stream_progress {
    my ( $self, $summary ) = @_;
    return 0 if !$self->listener_should_send_typing( $summary, 'claude-session' );
    return 1;
}

sub listener_progress_text {
    my ( $self, $stage, $tick ) = @_;
    if ( defined $stage && $stage eq 'start' ) {
        return 'Claude is working on your request in this session. I will send the final result when the work is done.';
    }
    return 'Claude is still working on your request...';
}

sub listener_progress_interval_seconds {
    my ($self) = @_;
    return 5;
}

sub start_listener_verbose_reporter {
    my ( $self, $summary, %args ) = @_;
    return undef if !$self->listener_should_send_typing( $summary, 'claude-session' );
    return undef if !defined $summary->{chat} || !defined $summary->{chat}{id};
    return $self->start_telegram_verbose_reporter(
        chat_id             => $summary->{chat}{id},
        reply_to_message_id => $summary->{message_id},
        %args,
    );
}

sub start_telegram_verbose_reporter {
    my ( $self, %args ) = @_;
    my $chat_id = $args{chat_id};
    return undef if !defined $chat_id || $chat_id eq q{};
    my $reply_to_message_id = $args{reply_to_message_id};
    my $on_error = $args{on_error};
    my @lines;
    my $message_id;
    my $disabled = 0;
    my $emit = sub {
        my ($line) = @_;
        return 0 if $disabled;
        return 1 if !defined $line || $line eq q{};
        push @lines, $line if !@lines || $lines[-1] ne $line;
        @lines = $self->listener_verbose_trimmed_lines(@lines);
        my $text = $self->listener_verbose_text(@lines);
        if ( !defined $message_id ) {
            my $sent = eval {
                $self->telegram_post(
                    'sendMessage',
                    {
                        chat_id => $chat_id,
                        (
                            defined $reply_to_message_id
                            ? ( reply_to_message_id => $reply_to_message_id )
                            : ()
                        ),
                        text => $text,
                    }
                );
            };
            if ( my $error = $@ ) {
                chomp $error;
                $disabled = 1;
                $on_error->($error) if $on_error;
                return 0;
            }
            $message_id = $sent->{result}{message_id} if $sent && ref($sent) eq 'HASH' && $sent->{result};
            return 1;
        }
        my $ok = eval {
            $self->telegram_post(
                'editMessageText',
                {
                    chat_id    => $chat_id,
                    message_id => $message_id,
                    text       => $text,
                }
            );
            return 1;
        };
        if ( !$ok || $@ ) {
            my $error = $@;
            chomp $error;
            $disabled = 1;
            $on_error->($error) if $on_error;
            return 0;
        }
        return 1;
    };
    return {
        emit   => $emit,
        finish => sub { return 1; },
    };
}

sub send_telegram_typing_action_for_chat {
    my ( $self, $chat_id ) = @_;
    return undef if !defined $chat_id || $chat_id eq q{};
    my $error = eval {
        $self->telegram_post(
            'sendChatAction',
            {
                chat_id => $chat_id,
                action  => 'typing',
            }
        );
        return undef;
    };
    if ( my $failure = $@ ) {
        chomp $failure;
        return {
            chat_id => $chat_id,
            error   => $failure,
        };
    }
    return undef;
}

sub listener_verbose_trimmed_lines {
    my ( $self, @lines ) = @_;
    my $max_lines = 12;
    @lines = @lines[ -$max_lines .. -1 ] if @lines > $max_lines;
    while (@lines) {
        my $text = $self->listener_verbose_text(@lines);
        last if length($text) <= 3500;
        shift @lines;
    }
    return @lines;
}

sub listener_verbose_text {
    my ( $self, @lines ) = @_;
    my @body = map { '- ' . $_ } @lines;
    return join "\n", 'Claude verbose', @body;
}

sub claude_progress_lines_for_event {
    my ( $self, $event ) = @_;
    return () if !$event || ref($event) ne 'HASH';
    my $type = $event->{type} || q{};
    if ( $type eq 'system' ) {
        return ('Session resumed') if ( $event->{subtype} || q{} ) eq 'init';
        return ();
    }
    return ('Turn completed') if $type eq 'result';
    return () if $type ne 'assistant' && $type ne 'user';
    my $message = $event->{message} || {};
    return () if ref($message) ne 'HASH';
    my $content = $message->{content};
    return () if ref($content) ne 'ARRAY';
    my @lines;
    for my $block ( @{$content} ) {
        next if ref($block) ne 'HASH';
        my $block_type = $block->{type} || q{};
        if ( $type eq 'assistant' && $block_type eq 'text' ) {
            my $text = $block->{text} || q{};
            $text =~ s/\r//g;
            push @lines, map { 'Agent: ' . $_ } grep { defined $_ && $_ ne q{} } split /\n+/, $text;
            next;
        }
        if ( $type eq 'assistant' && $block_type eq 'tool_use' ) {
            my $name = $block->{name} || 'tool';
            my $input = ref( $block->{input} ) eq 'HASH' ? $block->{input} : {};
            my $detail =
                defined $input->{command}   ? $input->{command}
              : defined $input->{file_path} ? $input->{file_path}
              :                               q{};
            push @lines, 'Running tool: ' . $name . ( $detail ne q{} ? ': ' . $detail : q{} );
            next;
        }
        if ( $type eq 'user' && $block_type eq 'tool_result' ) {
            my $result_content = $block->{content};
            my @output_lines;
            if ( defined $result_content && !ref $result_content ) {
                $result_content =~ s/\r//g;
                @output_lines = grep { defined $_ && $_ ne q{} } split /\n+/, $result_content;
            }
            elsif ( ref($result_content) eq 'ARRAY' ) {
                for my $chunk ( @{$result_content} ) {
                    next if ref($chunk) ne 'HASH';
                    next if ( $chunk->{type} || q{} ) ne 'text';
                    my $chunk_text = defined $chunk->{text} ? $chunk->{text} : q{};
                    $chunk_text =~ s/\r//g;
                    push @output_lines, grep { defined $_ && $_ ne q{} } split /\n+/, $chunk_text;
                }
            }
            splice @output_lines, 4 if @output_lines > 4;
            push @lines, map { 'Output: ' . $_ } @output_lines;
            next;
        }
    }
    return @lines;
}

sub claude_session_reply_prompt {
    my ( $self, $summary ) = @_;
    my $text = defined $summary->{text} ? $summary->{text} : q{};
    my $caption = defined $summary->{caption} ? $summary->{caption} : q{};
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : q{};
    my $message_id = defined $summary->{message_id} ? $summary->{message_id} : q{};
    my $session_id = $self->resolve_claude_reply_session_id;
    my $recent_transcript = $self->claude_session_recent_transcript_block($session_id);
    return join "\n",
        'A Telegram user sent a message to this active Claude session.',
        'Reply as this Claude session, using the current conversation context.',
        (
            $recent_transcript ne q{}
            ? (
                'Recent shared Claude session transcript:',
                $recent_transcript,
              )
            : ()
        ),
        'Return only the exact Telegram reply text. No markdown fences. No explanations. No tool narration.',
        'Do not prepend greetings, acknowledgements, or status prefaces unless the user explicitly asked for them. Start with the answer or result.',
        'Downloaded Telegram images are attached to this Claude prompt as real image inputs when available.',
        'Any *_local_path values below are already downloaded locally for this active Claude session.',
        'Non-image files remain available through the local paths below for tool-based inspection.',
        'Do not claim the attachment was not downloaded when a *_local_path value is present.',
        'For an outbound file reply, return directive lines instead of plain prose:',
        'telegram_attachment_type=photo|audio|document',
        'telegram_attachment_path=/absolute/local/path',
        'telegram_attachment_caption=optional caption',
        (
            $self->telegram_message_requires_completion($summary)
            ? (
                'Do the actual work in this resumed Claude session before you reply.',
                'Do not send promise-only replies such as "will be done", "working on it", or "I will do it".',
                'Only reply after the work is complete or you hit a concrete blocker you cannot resolve in-session.',
              )
            : ()
        ),
        "chat_id=$chat_id",
        "message_id=$message_id",
        "text=$text",
      "caption=$caption",
      $self->telegram_media_prompt_lines($summary);
}

sub claude_session_retry_prompt {
    my ( $self, $summary, $prior_reply ) = @_;
    return join "\n",
      $self->claude_session_reply_prompt($summary),
      'The prior reply was only a promise or progress update and must not be sent to Telegram.',
      'Continue the actual work in-session now and return only the final result or a concrete unresolved blocker.';
}

sub sync_telegram_exchange_to_claude_session {
    my ( $self, $session_id, $summary, $reply ) = @_;
    return 0 if !defined $session_id || $session_id eq q{};
    my $path = $self->claude_session_transcript_path($session_id);
    return 0 if !defined $path || $path eq q{};
    my $user_text = $self->telegram_session_user_sync_text($summary);
    my $assistant_text = $self->telegram_session_assistant_sync_text( $summary, $reply );
    my $message_id = defined $summary->{message_id} ? $summary->{message_id} : q{};
    my $wrote = 0;
    if ( defined $user_text && $user_text ne q{} ) {
        my $marker = "[Telegram chat " . ( defined $summary->{chat} ? $summary->{chat}{id} : q{} ) . " message $message_id]";
        if (
            $self->append_claude_session_message(
            $path,
            role    => 'user',
            text    => $user_text,
            marker  => $marker,
            session => $session_id,
            )
          )
        {
            $wrote = 1;
        }
    }
    if ( defined $assistant_text && $assistant_text ne q{} ) {
        my $marker = "[Telegram reply chat " . ( defined $summary->{chat} ? $summary->{chat}{id} : q{} ) . " message $message_id]";
        if (
            $self->append_claude_session_message(
            $path,
            role    => 'assistant',
            text    => $assistant_text,
            marker  => $marker,
            session => $session_id,
            )
          )
        {
            $wrote = 1;
        }
    }
    return $wrote ? 1 : 0;
}

sub telegram_session_user_sync_text {
    my ( $self, $summary ) = @_;
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : q{};
    my $message_id = defined $summary->{message_id} ? $summary->{message_id} : q{};
    my @body;
    push @body, $summary->{text} if defined $summary->{text} && $summary->{text} ne q{};
    push @body, '[caption] ' . $summary->{caption} if defined $summary->{caption} && $summary->{caption} ne q{};
    push @body, $self->telegram_session_media_summary_lines($summary);
    return q{} if !@body;
    return join "\n", "[Telegram chat $chat_id message $message_id]", @body;
}

sub telegram_session_assistant_sync_text {
    my ( $self, $summary, $reply ) = @_;
    return q{} if !defined $reply || $reply eq q{};
    my $chat_id = defined $summary->{chat} ? $summary->{chat}{id} : q{};
    my $message_id = defined $summary->{message_id} ? $summary->{message_id} : q{};
    return join "\n", "[Telegram reply chat $chat_id message $message_id]", $reply;
}

sub telegram_session_media_summary_lines {
    my ( $self, $summary ) = @_;
    my @lines;
    if ( $summary->{photo} ) {
        push @lines, '[photo] ' . ( $summary->{photo}{local_path} || $summary->{photo}{file_id} || 'attachment' );
    }
    if ( $summary->{document} ) {
        push @lines, '[document] ' . ( $summary->{document}{local_path} || $summary->{document}{file_name} || $summary->{document}{file_id} || 'attachment' );
    }
    if ( $summary->{audio} ) {
        push @lines, '[audio] ' . ( $summary->{audio}{local_path} || $summary->{audio}{title} || $summary->{audio}{file_id} || 'attachment' );
    }
    if ( $summary->{video} ) {
        push @lines, '[video] ' . ( $summary->{video}{local_path} || $summary->{video}{file_id} || 'attachment' );
    }
    if ( $summary->{voice} ) {
        push @lines, '[voice] ' . ( $summary->{voice}{local_path} || $summary->{voice}{file_id} || 'attachment' );
    }
    return @lines;
}

sub claude_session_recent_transcript_block {
    my ( $self, $session_id ) = @_;
    my @messages = $self->claude_session_recent_messages($session_id);
    return q{} if !@messages;
    return join "\n", map { $_->{role} . ': ' . $_->{text} } @messages;
}

sub claude_session_recent_messages {
    my ( $self, $session_id, %args ) = @_;
    my $path = $self->claude_session_transcript_path($session_id);
    return () if !defined $path || !-f $path;
    my $limit = $args{limit} || 8;
    my @messages;
    for my $line ( grep { defined $_ && $_ ne q{} } split /\n/, $self->read_text_file($path) ) {
        my $decoded = eval { decode_json($line) };
        next if $@ || ref($decoded) ne 'HASH';
        my $message = $self->claude_session_message_from_record($decoded);
        next if !$message;
        push @messages, $message;
    }
    @messages = @messages[ -$limit .. -1 ] if @messages > $limit;
    return @messages;
}

sub claude_session_message_from_record {
    my ( $self, $row ) = @_;
    return undef if !$row || ref($row) ne 'HASH';
    my $type = $row->{type} || q{};
    return undef if $type ne 'user' && $type ne 'assistant';
    my $message = $row->{message} || {};
    return undef if ref($message) ne 'HASH';
    my $role = $message->{role} || $type;
    return undef if $role ne 'user' && $role ne 'assistant';
    my $text = $self->claude_session_message_text_from_payload($message);
    return undef if !defined $text || $text eq q{};
    return {
        role => $role,
        text => $text,
    };
}

sub claude_session_message_text_from_payload {
    my ( $self, $payload ) = @_;
    my $content = $payload->{content};
    my @parts;
    push @parts, $content if defined $content && !ref $content;
    for my $chunk ( ref($content) eq 'ARRAY' ? @{$content} : () ) {
        next if ref($chunk) ne 'HASH';
        next if ( $chunk->{type} || q{} ) ne 'text';
        next if !defined $chunk->{text};
        push @parts, $chunk->{text};
    }
    my $text = join "\n", @parts;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    return q{} if $text eq q{};
    return $self->normalise_claude_session_message_text($text);
}

sub normalise_claude_session_message_text {
    my ( $self, $text ) = @_;
    return q{} if !defined $text || $text eq q{};
    if ( $text =~ /\AA Telegram user sent a message to this active Claude session\./ ) {
        my ($chat_id) = $text =~ /^chat_id=(.+)$/m;
        my ($message_id) = $text =~ /^message_id=(.+)$/m;
        my ($body) = $text =~ /^text=(.*)$/m;
        my ($caption) = $text =~ /^caption=(.*)$/m;
        my @lines;
        push @lines, $body if defined $body && $body ne q{};
        push @lines, '[caption] ' . $caption if defined $caption && $caption ne q{};
        return join "\n", "[Telegram chat $chat_id message $message_id]", @lines if @lines;
    }
    return $text;
}

sub claude_session_transcript_path {
    my ( $self, $session_id ) = @_;
    return undef if !defined $session_id || $session_id eq q{};
    my $root = File::Spec->catdir( $self->resolve_path('~/.claude'), 'projects' );
    return undef if !-d $root;
    my @matches = sort glob File::Spec->catfile( $root, '*', "$session_id.jsonl" );
    return $matches[-1] if @matches;
    return undef;
}

sub append_claude_session_message {
    my ( $self, $path, %args ) = @_;
    return 0 if !defined $path || $path eq q{};
    my $role = $args{role} || q{};
    my $text = $args{text};
    my $marker = $args{marker} || q{};
    return 0 if $text !~ /\S/;
    if ( $marker ne q{} && -f $path ) {
        my $existing = $self->read_text_file($path);
        return 0 if index( $existing, $marker ) >= 0;
    }
    my $timestamp = $self->now_iso8601_z;
    my $row = {
        timestamp => $timestamp,
        type      => $role,
        message   => {
            role    => $role,
            content => [
                {
                    type => 'text',
                    text => $text,
                },
            ],
        },
    };
    open my $fh, '>>', $path or die "Unable to append $path: $!";
    print {$fh} encode_json($row) . "\n";
    close $fh or die "Unable to close $path: $!";
    return 1;
}

sub telegram_message_requires_completion {
    my ( $self, $summary ) = @_;
    my $body = join q{ }, grep { defined $_ && $_ ne q{} } ( $summary->{text}, $summary->{caption} );
    return 0 if $body eq q{};
    return $body =~ /\b(?:finish|complete|continue|do it|fix|investigate|update|implement|run|check|review|audit|verify|inspect|analy[sz]e|test|all gates|all tasks)\b/i ? 1 : 0;
}

sub telegram_reply_is_promise_placeholder {
    my ( $self, $reply ) = @_;
    return 0 if !defined $reply || $reply eq q{};
    my $normalized = lc $reply;
    $normalized =~ s/[\r\n]+/ /g;
    $normalized =~ s/\s+/ /g;
    return $normalized =~ /\b(?:will be done|working on it|i will do it|i'll do it|i am working on it|i'm working on it|i will finish it|i'll finish it)\b/
      ? 1
      : 0;
}

sub mapped_claude_session_from_config {
    my ( $self, $config ) = @_;
    $config = eval { $self->read_claude_config( $self->claude_config_path ) } if !defined $config;
    return undef if !$config || ref($config) ne 'HASH';
    my $workspace_key = $self->workspace_session_id;
    my @keys = grep { defined $_ && $_ ne q{} } ($workspace_key);
    for my $key (@keys) {
        my $mapped = $config->{$key};
        return $mapped if defined $mapped && $mapped ne q{};
    }
    return undef;
}

sub telegram_media_prompt_lines {
    my ( $self, $summary ) = @_;
    my @lines;
    if ( $summary->{photo} ) {
        push @lines, 'photo_file_id=' . ( $summary->{photo}{file_id} || q{} );
        push @lines, 'photo_local_path=' . ( $summary->{photo}{local_path} || q{} ) if $summary->{photo}{local_path};
    }
    if ( $summary->{document} ) {
        push @lines, 'document_file_id=' . ( $summary->{document}{file_id} || q{} );
        push @lines, 'document_name=' . ( $summary->{document}{file_name} || q{} );
        push @lines, 'document_mime=' . ( $summary->{document}{mime_type} || q{} );
        push @lines, 'document_local_path=' . ( $summary->{document}{local_path} || q{} ) if $summary->{document}{local_path};
    }
    if ( $summary->{audio} ) {
        push @lines, 'audio_file_id=' . ( $summary->{audio}{file_id} || q{} );
        push @lines, 'audio_title=' . ( $summary->{audio}{title} || q{} );
        push @lines, 'audio_mime=' . ( $summary->{audio}{mime_type} || q{} );
        push @lines, 'audio_local_path=' . ( $summary->{audio}{local_path} || q{} ) if $summary->{audio}{local_path};
    }
    if ( $summary->{video} ) {
        push @lines, 'video_file_id=' . ( $summary->{video}{file_id} || q{} );
        push @lines, 'video_mime=' . ( $summary->{video}{mime_type} || q{} );
        push @lines, 'video_duration=' . ( $summary->{video}{duration} || q{} );
        push @lines, 'video_local_path=' . ( $summary->{video}{local_path} || q{} ) if $summary->{video}{local_path};
    }
    if ( $summary->{voice} ) {
        push @lines, 'voice_file_id=' . ( $summary->{voice}{file_id} || q{} );
        push @lines, 'voice_mime=' . ( $summary->{voice}{mime_type} || q{} );
        push @lines, 'voice_duration=' . ( $summary->{voice}{duration} || q{} );
        push @lines, 'voice_local_path=' . ( $summary->{voice}{local_path} || q{} ) if $summary->{voice}{local_path};
    }
    return @lines;
}

sub claude_session_image_input_paths {
    my ( $self, $summary ) = @_;
    return () if !$summary || ref($summary) ne 'HASH';
    my @paths;
    push @paths, $summary->{photo}{local_path}
      if $summary->{photo} && $summary->{photo}{local_path};
    if ( $summary->{document} && $summary->{document}{local_path} && $self->telegram_document_is_image( $summary->{document} ) ) {
        push @paths, $summary->{document}{local_path};
    }
    my %seen;
    return grep { defined $_ && $_ ne q{} && !$seen{$_}++ } @paths;
}

sub telegram_document_is_image {
    my ( $self, $document ) = @_;
    return 0 if !$document || ref($document) ne 'HASH';
    my $mime = defined $document->{mime_type} ? lc $document->{mime_type} : q{};
    return 1 if $mime =~ m{\Aimage/};
    my $name = defined $document->{file_name} ? lc $document->{file_name} : q{};
    return $name =~ /\.(?:png|jpe?g|webp|gif|bmp|tiff?)\z/ ? 1 : 0;
}

sub write_claude_target_session_id {
    my ( $self, $session_id, $target_session_id ) = @_;
    return if !defined $target_session_id || $target_session_id eq q{};
    my $path = $self->listener_paths_for_session($session_id)->{target_session_file};
    return $self->write_text_file( $path, $target_session_id . "\n" );
}

sub read_claude_target_session_id {
    my ( $self, $path ) = @_;
    return undef if !defined $path || !-f $path;
    my $content = $self->read_text_file($path);
    $content =~ s/\s+\z//;
    return $content eq q{} ? undef : $content;
}

sub listener_pause_seconds {
    my ( $self, $seconds ) = @_;
    $seconds = 1 if !defined $seconds;
    if ( $self->{sleep_runner} ) {
        return $self->{sleep_runner}->($seconds);
    }
    select undef, undef, undef, $seconds;
    return $seconds;
}

sub append_inbox_entry {
    my ( $self, $path, $entry ) = @_;
    make_path( dirname($path) ) if !-d dirname($path);
    open my $fh, '>>', $path or die "Unable to append $path: $!";
    print {$fh} encode_json($entry) . "\n";
    close $fh or die "Unable to close $path: $!";
    return $path;
}

sub update_needs_listener_reply {
    my ( $self, $summary ) = @_;
    return 1 if defined $summary->{text}     && $summary->{text} ne q{};
    return 1 if defined $summary->{caption}  && $summary->{caption} ne q{};
    return 1 if $summary->{photo};
    return 1 if $summary->{document};
    return 1 if $summary->{audio};
    return 1 if $summary->{video};
    return 1 if $summary->{voice};
    return 0;
}

sub summary_has_media {
    my ( $self, $summary ) = @_;
    return 1 if $summary->{photo};
    return 1 if $summary->{document};
    return 1 if $summary->{audio};
    return 1 if $summary->{video};
    return 1 if $summary->{voice};
    return 0;
}

sub resolve_token {
    my ( $self, $explicit ) = @_;
    my $token = defined $explicit && $explicit ne q{}
      ? $explicit
      : $self->env_value('TELEGRAM_BOT_TOKEN');
    die "TELEGRAM_BOT_TOKEN is required\n" if !defined $token || $token eq q{};
    return $token;
}

sub env_value {
    my ( $self, $key ) = @_;
    return $self->{env}{$key};
}

sub resolve_path {
    my ( $self, $path ) = @_;
    return undef if !defined $path;
    if ( $path eq '~' ) {
        return $self->{home};
    }
    if ( defined $self->{home} && $path =~ m{\A~/} ) {
        return File::Spec->catfile( $self->{home}, substr( $path, 2 ) );
    }
    return $path;
}

sub basename {
    my ( $self, $path ) = @_;
    $path =~ s{\\}{/}g;
    my @parts = split m{/}, $path;
    return $parts[-1];
}

sub safe_filename {
    my ( $self, $name ) = @_;
    $name = defined $name ? $name : 'file.bin';
    $name =~ s{[^\w.\-]+}{-}g;
    $name =~ s{\A-+}{};
    $name =~ s{-+\z}{};
    return $name eq q{} ? 'file.bin' : $name;
}

sub encode_pretty_json {
    my ( $self, $data ) = @_;
    return JSON::XS->new->utf8->pretty->canonical->encode($data);
}

sub write_text_file {
    my ( $self, $path, $content ) = @_;
    make_path( dirname($path) ) if !-d dirname($path);
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content;
    close $fh or die "Unable to close $path: $!";
    return $path;
}

sub read_text_file {
    my ( $self, $path ) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $content;
}

sub _build_ua {
    my ($self) = @_;
    my $ua = LWP::UserAgent->new(
            agent   => 'telegram-claude/' . ( $self->env_value('VERSION') || '0.33' ),
        timeout => 60,
    );
    return $ua;
}

sub _default_skill_root {
    my ($class) = @_;
    return File::Spec->rel2abs(
        File::Spec->catdir( dirname(__FILE__), File::Spec->updir, File::Spec->updir, File::Spec->updir )
    );
}

sub _merged_env {
    my ($self) = @_;
    my %env = %ENV;
    my %from_file;
    for my $skill_env ( $self->_env_candidate_files ) {
        next if !-f $skill_env;
        open my $fh, '<', $skill_env or die "Unable to read $skill_env: $!";
        while ( my $line = <$fh> ) {
            chomp $line;
            next if $line !~ /^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/;
            next if $from_file{$1}++;
            $env{$1} = $2;
        }
        close $fh or die "Unable to close $skill_env: $!";
    }
    return \%env;
}

sub _env_candidate_files {
    my ($self) = @_;
    my @files;
    my %seen;
    my $dir = $self->{cwd};
    while ( defined $dir && $dir ne q{} ) {
        my $path = File::Spec->catfile( $dir, '.env' );
        if ( !$seen{$path}++ ) {
            push @files, $path;
        }
        my $parent = dirname($dir);
        last if !defined $parent || $parent eq $dir;
        $dir = $parent;
    }
    my $skill_root_env = File::Spec->catfile( $self->{skill_root}, '.env' );
    if ( !$seen{$skill_root_env}++ ) {
        push @files, $skill_root_env;
    }
    return @files;
}

1;
