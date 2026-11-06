import std;
import gosh_types;
import gosh_os;
import lexer;
import parser;
import expansion;
import builtins;
import executor;
import prompt;
import completion;
import line_editor;
import os;

fn init_state(state: ShellState&) {
    gosh_init_signals();

    state.pid = gosh_get_pid();
    state.running = true;
    state.last_status = 0;
    state.var_count = 0;
    state.alias_count = 0;
    state.func_count = 0;
    state.job_count = 0;
    state.hist_count = 0;
    state.emacs_mode = true;
    state.syntax_highlight = true;
    state.autosuggest = true;

    // Load CWD
    var cwd_buf: u8[1024] = [0; 1024];
    let clen = gosh_getcwd(cwd_buf);
    if clen > 0 {
        format(state.cwd, cwd_buf[..clen]);
    }

    // Load HOME
    var home_buf: u8[>..] = [];
    if env("HOME", home_buf) {
        format(state.home, home_buf);
    }

    // Load USER
    var user_buf: u8[>..] = [];
    if env("USER", user_buf) {
        format(state.user, user_buf);
    }

    // Load HOSTNAME
    var host_buf: u8[>..] = [];
    if env("HOSTNAME", host_buf) {
        format(state.hostname, host_buf);
    } else {
        format(state.hostname, "localhost");
    }

    // Load environment variables into state.vars
    let env_count = gosh_get_env_count();
    for i in env_count {
        if state.vars.len >= 128 { break; }
        var k_buf: u8[256] = [0; 256];
        var v_buf: u8[1024] = [0; 1024];
        let ok = gosh_get_env_entry(i, k_buf, v_buf);
        if ok != 0 {
            var k_len = find(k_buf, "\0");
            var v_len = find(v_buf, "\0");
            if k_len < 0 { k_len = 256; }
            if v_len < 0 { v_len = 1024; }
            if k_len > 64 { k_len = 64; }
            if v_len > 512 { v_len = 512; }

            var v = ShellVar { exported: true };
            format(v.name, k_buf[..k_len]);
            format(v.val, v_buf[..v_len]);
            state.vars.push(v);
            state.var_count++;
        }
    }

    // Set GOSH metadata
    set_var(state, "GOSH_VERSION", "1.0.0", false);
    set_var(state, "SHELL", "gosh", true);

    // Default aliases
    var a_ll = ShellAlias {};
    format(a_ll.name, "ll");
    format(a_ll.val, "ls -la");
    state.aliases.push(a_ll);

    var a_la = ShellAlias {};
    format(a_la.name, "la");
    format(a_la.val, "ls -A");
    state.aliases.push(a_la);

    state.alias_count = state.aliases.len as i32;
}

fn add_history(state: ShellState&, line: const u8[:]) {
    if line.len == 0 { return; }
    // Avoid duplicate of most recent line
    if state.hist_count > 0 && state.hist_lines[state.hist_count - 1] == line {
        return;
    }

    if state.hist_lines.len < 256 {
        var h: u8[..256] = [];
        format(h, line);
        state.hist_lines.push(h);
        state.hist_count = state.hist_lines.len as i32;
    } else {
        // Shift left
        remove_at(state.hist_lines, 0);
        var h: u8[..256] = [];
        format(h, line);
        state.hist_lines.push(h);
    }
}

fn print_welcome_banner() {
    print("""
\033[1;36m  ██████╗  ██████╗ ███████╗██╗  ██╗\033[0m
\033[1;36m ██╔════╝ ██╔═══██╗██╔════╝██║  ██║\033[0m   GOSH — Native Unix Shell in Goose v1.0.0
\033[1;36m ██║  ███╗██║   ██║███████╗███████║\033[0m   Type 'help' for builtins and features
\033[1;36m ██║   ██║██║   ██║╚════██║██╔══██║\033[0m   Press TAB for completions, Right Arrow for suggestions
\033[1;36m ╚██████╔╝╚██████╔╝███████║██║  ██║\033[0m
\033[1;36m  ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝\033[0m
""");
}

fn main() {
    var state = ShellState {};
    init_state(state);

    let argc = arg_count();

    // Check command line flags
    if argc > 1 {
        var arg1: u8[>..] = [];
        arg(1, arg1);

        if arg1 == "-v" || arg1 == "--version" {
            print("gosh version 1.0.0 (Goose Native Unix Shell)");
            return;
        }

        if arg1 == "-h" || arg1 == "--help" {
            builtin_help();
            return;
        }

        if arg1 == "-c" && argc > 2 {
            var cmd_str: u8[>..] = [];
            arg(2, cmd_str);
            format(state.script_name, "gosh");
            for i in 3..argc {
                var a: u8[>..] = [];
                arg(i, a);
                var s_arg: u8[..128] = [];
                format(s_arg, a);
                if state.script_args.len < 16 {
                    state.script_args.push(s_arg);
                }
            }
            let status = execute_script(state, cmd_str);
            if status != 0 {
                gosh_exit(status);
            }
            return;
        }

        // Script execution: gosh script.gosh [args...]
        if !starts_with(arg1, "-") {
            format(state.script_name, arg1);
            for i in 2..argc {
                var a: u8[>..] = [];
                arg(i, a);
                var s_arg: u8[..128] = [];
                format(s_arg, a);
                if state.script_args.len < 16 {
                    state.script_args.push(s_arg);
                }
            }
            let status = source_file(state, arg1);
            if status != 0 {
                gosh_exit(status);
            }
            return;
        }
    }

    // Interactive REPL
    state.interactive = gosh_term_isatty(0) != 0;
    if state.interactive {
        // Check for ~/.goshrc
        if state.home.len > 0 {
            var goshrc_path: u8[>..] = [];
            format(goshrc_path, state.home, "/.goshrc");
            if gosh_file_exists(goshrc_path) != 0 {
                source_file(state, goshrc_path);
            }
        }
        if !state.running {
            gosh_exit(state.last_status);
            return;
        }
        print_welcome_banner();
    }

    while state.running {
        poll_jobs(state);
        var line: u8[..512] = [];
        let ok = read_interactive_line(state, line);
        if !ok {
            // EOF reached
            break;
        }

        let trimmed = trim(line);
        if trimmed.len > 0 {
            add_history(state, trimmed);
            execute_script(state, trimmed);
        }
    }
}
