import std;
import gosh_types;
import gosh_os;
import lexer;
import parser;
import expansion;
import builtins;
import os;

// Builtin runner dispatch
recursive fn dispatch_builtin(state: ShellState&, cmd: const u8[:], args: const u8[..128][..16]&) -> i32 {
    if cmd == "echo" { return builtin_echo(args); }
    if cmd == "cd" { return builtin_cd(state, args); }
    if cmd == "pwd" { return builtin_pwd(state); }
    if cmd == "export" { return builtin_export(state, args); }
    if cmd == "unset" { return builtin_unset(state, args); }
    if cmd == "set" { return builtin_set(state); }
    if cmd == "alias" { return builtin_alias(state, args); }
    if cmd == "unalias" { return builtin_unalias(state, args); }
    if cmd == "history" { return builtin_history(state); }
    if cmd == "type" { return builtin_type(state, args); }
    if cmd == "test" || cmd == "[" { return builtin_test(args); }
    if cmd == "printf" { return builtin_printf(args); }
    if cmd == "jobs" { return builtin_jobs(state); }
    if cmd == "fg" { return builtin_fg(state, args); }
    if cmd == "bg" { return builtin_bg(state, args); }
    if cmd == "source" || cmd == "." {
        if args.len > 1 {
            return source_file(state, args[1]);
        }
        print("gosh: source: filename argument required");
        return 1;
    }
    if cmd == "command" {
        if args.len <= 1 { return 0; }
        var sub_args: u8[..128][..16] = [];
        for k in 1..args.len {
            sub_args.push(args[k]);
        }
        let sub_name = sub_args[0];
        if is_builtin(sub_name) {
            return dispatch_builtin(state, sub_name, sub_args);
        }
        var packed: u8[>..] = [];
        for a in sub_args {
            packed.append(a);
            packed.push(0);
        }
        var dummy_pid: i32 = 0;
        return gosh_exec_packed(packed, sub_args.len as i32, "", "", 0, "", 0, 0, 0, dummy_pid);
    }
    if cmd == "help" { return builtin_help(); }
    if cmd == "exit" {
        state.running = false;
        if args.len > 1 {
            let code, ok = parse_int(args[1]);
            return if ok { code as i32 } else { 0 };
        }
        return state.last_status;
    }
    return 1;
}

// Apply redirections in source order; callers in the shell must save/restore stdio.
fn apply_redirections(state: ShellState&, redirs: const Redirection[..4]&) -> bool {
    for r in redirs {
        var exp_target: u8[..128] = [];
        expand_word(state, r.target, exp_target);

        if r.kind == TOKEN_REDIR_IN {
            let fd = gosh_open_file(exp_target, 0);
            if fd < 0 {
                print("gosh: ", exp_target, ": No such file or directory");
                return false;
            }
            let result = gosh_dup2(fd, 0);
            if fd != 0 { gosh_close(fd); }
            if result < 0 { return false; }
        } else if r.kind == TOKEN_REDIR_OUT {
            let fd = gosh_open_file(exp_target, 1);
            if fd < 0 {
                print("gosh: cannot create ", exp_target);
                return false;
            }
            let result = gosh_dup2(fd, 1);
            if fd != 1 { gosh_close(fd); }
            if result < 0 { return false; }
        } else if r.kind == TOKEN_REDIR_APP {
            let fd = gosh_open_file(exp_target, 2);
            if fd < 0 {
                print("gosh: cannot create ", exp_target);
                return false;
            }
            let result = gosh_dup2(fd, 1);
            if fd != 1 { gosh_close(fd); }
            if result < 0 { return false; }
        } else if r.kind == TOKEN_REDIR_ERR {
            let fd = gosh_open_file(exp_target, 1);
            if fd < 0 {
                print("gosh: cannot create ", exp_target);
                return false;
            }
            let result = gosh_dup2(fd, 2);
            if fd != 2 { gosh_close(fd); }
            if result < 0 { return false; }
        } else if r.kind == TOKEN_REDIR_ERR_APP {
            let fd = gosh_open_file(exp_target, 2);
            if fd < 0 {
                print("gosh: cannot create ", exp_target);
                return false;
            }
            let result = gosh_dup2(fd, 2);
            if fd != 2 { gosh_close(fd); }
            if result < 0 { return false; }
        } else if r.kind == TOKEN_REDIR_E2O {
            if gosh_dup2(1, 2) < 0 { return false; }
        } else if r.kind == TOKEN_REDIR_BOTH {
            let fd = gosh_open_file(exp_target, 1);
            if fd < 0 {
                print("gosh: cannot create ", exp_target);
                return false;
            }
            let out_result = gosh_dup2(fd, 1);
            let err_result = gosh_dup2(fd, 2);
            if fd != 1 && fd != 2 { gosh_close(fd); }
            if out_result < 0 || err_result < 0 { return false; }
        }
    }
    return true;
}

// Execute command in child process
recursive fn execute_cmd_in_child(state: ShellState&, raw_cmd: const Command&) {
    if !apply_redirections(state, raw_cmd.redirs) {
        gosh_exit(1);
    }

    if raw_cmd.is_assignment && raw_cmd.arg_count == 0 {
        var exp_val: u8[..128] = [];
        expand_word(state, raw_cmd.assign_val, exp_val);
        gosh_exit(set_var(state, raw_cmd.assign_var, exp_val, false));
    }

    var exp_args: u8[..128][..16] = [];
    expand_arguments(state, raw_cmd.argv, exp_args);

    if exp_args.len == 0 {
        gosh_exit(0);
    }

    let cmd_name = exp_args[0];

    // Functions
    for f in state.funcs {
        if f.name == cmd_name {
            state.script_args.clear();
            for k in 1..exp_args.len {
                state.script_args.push(exp_args[k]);
            }
            let st = execute_script(state, f.body);
            gosh_exit(st);
        }
    }

    // Aliases
    for a in state.aliases {
        if a.name == cmd_name {
            var full_line: u8[..1024] = [];
            format(full_line, a.val);
            for k in 1..exp_args.len {
                full_line.push(' ');
                format(full_line, exp_args[k]);
            }
            let st = execute_script(state, full_line);
            gosh_exit(st);
        }
    }

    // Builtins
    if is_builtin(cmd_name) {
        let st = dispatch_builtin(state, cmd_name, exp_args);
        gosh_exit(st);
    }

    // External command
    var packed: u8[..4096] = [];
    for arg in exp_args {
        packed.append(arg);
        packed.push(0);
    }
    let err = gosh_execvp_packed(packed, exp_args.len as i32);
    gosh_exit(err);
}

// Execute a single command
recursive fn execute_single_cmd(state: ShellState&, raw_cmd: const Command&) -> i32 {
    // 1. Variable assignment with no command (e.g. FOO=bar)
    if raw_cmd.is_assignment && raw_cmd.arg_count == 0 {
        var exp_val: u8[..128] = [];
        expand_word(state, raw_cmd.assign_val, exp_val);
        return set_var(state, raw_cmd.assign_var, exp_val, false);
    }

    // 2. Expand arguments
    var exp_args: u8[..128][..16] = [];
    expand_arguments(state, raw_cmd.argv, exp_args);

    if exp_args.len == 0 {
        return 0;
    }

    let cmd_name = exp_args[0];

    // 3. Check for shell function
    for f in state.funcs {
        if f.name == cmd_name {
            let saved_args = state.script_args;
            state.script_args.clear();
            for k in 1..exp_args.len {
                state.script_args.push(exp_args[k]);
            }
            let res = execute_script(state, f.body);
            state.script_args = saved_args;
            return res;
        }
    }

    // 4. Check for alias
    for a in state.aliases {
        if a.name == cmd_name {
            var full_line: u8[..1024] = [];
            format(full_line, a.val);
            for k in 1..exp_args.len {
                full_line.push(' ');
                format(full_line, exp_args[k]);
            }
            return execute_script(state, full_line);
        }
    }

    // 5. Check for builtin (executed in parent shell process)
    if is_builtin(cmd_name) {
        if raw_cmd.redirs.len > 0 {
            var in_file: u8[..128] = [];
            var out_file: u8[..128] = [];
            var append_out: i32 = 0;
            var err_file: u8[..128] = [];
            var append_err: i32 = 0;
            var redirect_err_to_out: i32 = 0;

            for r in raw_cmd.redirs {
                var exp_target: u8[..128] = [];
                expand_word(state, r.target, exp_target);
                if r.kind == TOKEN_REDIR_IN { format(in_file, exp_target); }
                else if r.kind == TOKEN_REDIR_OUT { out_file.clear(); format(out_file, exp_target); append_out = 0; }
                else if r.kind == TOKEN_REDIR_APP { out_file.clear(); format(out_file, exp_target); append_out = 1; }
                else if r.kind == TOKEN_REDIR_ERR { err_file.clear(); format(err_file, exp_target); append_err = 0; }
                else if r.kind == TOKEN_REDIR_ERR_APP { err_file.clear(); format(err_file, exp_target); append_err = 1; }
                else if r.kind == TOKEN_REDIR_E2O { redirect_err_to_out = 1; }
                else if r.kind == TOKEN_REDIR_BOTH { out_file.clear(); format(out_file, exp_target); redirect_err_to_out = 1; }
            }

            var saved_fds: i32[3] = [-1, -1, -1];
            gosh_redirect_begin(in_file, out_file, append_out, err_file, append_err, redirect_err_to_out, saved_fds[0]);
            let status = dispatch_builtin(state, cmd_name, exp_args);
            gosh_redirect_end(saved_fds[0]);
            return status;
        }
        return dispatch_builtin(state, cmd_name, exp_args);
    }

    // 6. External command execution
    var in_file: u8[..256] = [];
    var out_file: u8[..256] = [];
    var append_out: i32 = 0;
    var err_file: u8[..256] = [];
    var append_err: i32 = 0;
    var redirect_err_to_out: i32 = 0;

    for r in raw_cmd.redirs {
        var exp_target: u8[..128] = [];
        expand_word(state, r.target, exp_target);

        if r.kind == TOKEN_REDIR_IN {
            in_file.clear();
            format(in_file, exp_target);
        } else if r.kind == TOKEN_REDIR_OUT {
            out_file.clear();
            format(out_file, exp_target);
            append_out = 0;
        } else if r.kind == TOKEN_REDIR_APP {
            out_file.clear();
            format(out_file, exp_target);
            append_out = 1;
        } else if r.kind == TOKEN_REDIR_ERR {
            err_file.clear();
            format(err_file, exp_target);
            append_err = 0;
        } else if r.kind == TOKEN_REDIR_ERR_APP {
            err_file.clear();
            format(err_file, exp_target);
            append_err = 1;
        } else if r.kind == TOKEN_REDIR_E2O {
            redirect_err_to_out = 1;
        } else if r.kind == TOKEN_REDIR_BOTH {
            out_file.clear();
            format(out_file, exp_target);
            redirect_err_to_out = 1;
        }
    }

    var packed: u8[..4096] = [];
    for arg in exp_args {
        packed.append(arg);
        packed.push(0);
    }

    var child_pid: i32 = 0;
    let status = gosh_exec_packed(
        packed,
        exp_args.len as i32,
        in_file,
        out_file,
        append_out,
        err_file,
        append_err,
        redirect_err_to_out,
        if raw_cmd.background { 1 } else { 0 },
        child_pid
    );

    if raw_cmd.background {
        state.last_bg_pid = child_pid;
        if state.job_count < 16 {
            var job = ShellJob {
                id: state.job_count + 1,
                pid: child_pid,
                running: true,
            };
            format(job.cmd, cmd_name);
            state.jobs.push(job);
            state.job_count = state.jobs.len as i32;
            if state.interactive {
                print("[", job.id, "] ", job.pid);
            }
        }
    }

    return status;
}

// Execute a pipeline
recursive fn execute_pipeline(state: ShellState&, pipe: const Pipeline&) -> i32 {
    let num_cmds = pipe.cmds.len;
    if num_cmds == 0 { return 0; }
    if num_cmds == 1 {
        let cmd = pipe.cmds[0];
        if cmd.background {
            let pid = gosh_fork();
            if pid < 0 { return -1; }
            if pid == 0 {
                gosh_reset_signals();
                gosh_setpgid(0, 0);
                execute_cmd_in_child(state, cmd);
                gosh_exit(0);
            }
            state.last_bg_pid = pid;
            if state.job_count < 16 {
                var job = ShellJob {
                    id: state.job_count + 1,
                    pid: pid,
                    running: true,
                };
                var name: u8[..64] = [];
                if cmd.argv.len > 0 { format(name, cmd.argv[0]); }
                format(job.cmd, name);
                state.jobs.push(job);
                state.job_count = state.jobs.len as i32;
                if state.interactive {
                print("[", job.id, "] ", job.pid);
            }
            }
            return 0;
        }
        return execute_single_cmd(state, cmd);
    }

    // Multi-command pipeline
    var pipes: i32[8] = [-1; 8];
    for k in (num_cmds - 1) {
        gosh_pipe(pipes[k * 2]);
    }

    var pids: i32[4] = [0; 4];
    for i in num_cmds {
        let pid = gosh_fork();
        if pid < 0 { return -1; }

        if pid == 0 {
            gosh_reset_signals();

            // Connect input from previous pipe
            if i > 0 {
                gosh_dup2(pipes[(i - 1) * 2], 0);
            }

            // Connect output to next pipe
            if i < num_cmds - 1 {
                gosh_dup2(pipes[i * 2 + 1], 1);
            }

            // Close all pipe fds in child
            for k in (num_cmds - 1) * 2 {
                gosh_close(pipes[k]);
            }

            execute_cmd_in_child(state, pipe.cmds[i]);
            gosh_exit(0);
        }

        pids[i] = pid;
    }

    // Parent closes all pipe fds
    for k in (num_cmds - 1) * 2 {
        gosh_close(pipes[k]);
    }

    if pipe.cmds[num_cmds - 1].background {
        state.last_bg_pid = pids[num_cmds - 1];
        if state.job_count < 16 {
            var job = ShellJob {
                id: state.job_count + 1,
                pid: pids[num_cmds - 1],
                running: true,
            };
            format(job.cmd, "pipeline");
            state.jobs.push(job);
            state.job_count = state.jobs.len as i32;
            if state.interactive {
                print("[", job.id, "] ", job.pid);
            }
        }
        return 0;
    }

    var last_status: i32 = 0;
    for i in num_cmds {
        let st = gosh_wait_pid(pids[i]);
        if i == num_cmds - 1 {
            last_status = st;
        }
    }
    return last_status;
}

// Control flow runs in the current shell; its caller owns descriptor cleanup.
recursive fn execute_compound_statement(state: ShellState&, stmt: const Statement&) -> i32 {
    if stmt.kind == STMT_IF {
        let cond_res = execute_script(state, stmt.cond_text);
        if cond_res == 0 {
            return execute_script(state, stmt.body_text);
        } else if stmt.else_text.len > 0 {
            return execute_script(state, stmt.else_text);
        }
        return 0;
    }

    if stmt.kind == STMT_WHILE {
        var last: i32 = 0;
        loop {
            if !state.running { break; }
            let cond_res = execute_script(state, stmt.cond_text);
            if cond_res != 0 { break; }
            last = execute_script(state, stmt.body_text);
        }
        return last;
    }

    if stmt.kind == STMT_FOR {
        var last: i32 = 0;
        for w in stmt.for_words {
            if !state.running { break; }
            var exp_w: u8[..128] = [];
            expand_word(state, w, exp_w);
            let assign_status = set_var(state, stmt.for_var, exp_w, false);
            if assign_status != 0 { return assign_status; }
            last = execute_script(state, stmt.body_text);
        }
        return last;
    }

    return 0;
}

// Execute a single AST statement (Pipeline, IF, WHILE, FOR, FUNCTION, SUBSHELL)
recursive fn execute_statement(state: ShellState&, stmt: const Statement&) -> i32 {
    if stmt.kind == STMT_PIPELINE {
        return execute_pipeline(state, stmt.pipeline);
    }

    if stmt.kind == STMT_SUBSHELL {
        let pid = gosh_fork();
        if pid < 0 { return -1; }
        if pid == 0 {
            gosh_reset_signals();
            if !apply_redirections(state, stmt.redirs) {
                gosh_exit(1);
            }
            let st = execute_script(state, stmt.body_text);
            gosh_exit(st);
        }
        return gosh_wait_pid(pid);
    }

    if stmt.kind == STMT_IF || stmt.kind == STMT_WHILE || stmt.kind == STMT_FOR {
        if stmt.redirs.len == 0 {
            return execute_compound_statement(state, stmt);
        }
        var saved_fds: i32[3] = [-1, -1, -1];
        if gosh_save_stdio(saved_fds[0]) < 0 { return 1; }
        var status: i32 = 1;
        if apply_redirections(state, stmt.redirs) {
            status = execute_compound_statement(state, stmt);
        }
        // Also unwind partially applied redirections and nonzero body statuses.
        if gosh_restore_stdio(saved_fds[0]) < 0 { return 1; }
        return status;
    }

    if stmt.kind == STMT_FUNC {
        var found = false;
        for &f in state.funcs {
            if f.name == stmt.func_name {
                f.body.clear();
                format(f.body, stmt.func_body);
                found = true;
                break;
            }
        }
        if !found && state.funcs.len < 64 {
            var f = ShellFunc {};
            format(f.name, stmt.func_name);
            format(f.body, stmt.func_body);
            state.funcs.push(f);
            state.func_count = state.funcs.len as i32;
        }
        return 0;
    }

    return 0;
}

// Execute a full script or command line string
recursive fn execute_script(state: ShellState&, script_text: const u8[:]) -> i32 {
    if script_text.len == 0 { return state.last_status; }

    var tokens: Token[..64] = [];
    tokenize_line(script_text, tokens);

    var stmts: Statement[..8] = [];
    parse_statements(tokens, stmts);

    var skip_next_and = false;
    var skip_next_or = false;

    for stmt in stmts {
        if !state.running { break; }

        if skip_next_and {
            skip_next_and = false;
            if stmt.op_after == OP_AND {
                skip_next_and = true;
            }
            continue;
        }

        if skip_next_or {
            skip_next_or = false;
            if stmt.op_after == OP_OR {
                skip_next_or = true;
            }
            continue;
        }

        state.last_status = execute_statement(state, stmt);

        if stmt.op_after == OP_AND {
            if state.last_status != 0 {
                skip_next_and = true;
            }
        } else if stmt.op_after == OP_OR {
            if state.last_status == 0 {
                skip_next_or = true;
            }
        }
    }

    return state.last_status;
}

// Source a script file
recursive fn source_file(state: ShellState&, path: const u8[:]) -> i32 {
    var script_buf: u8[..32768] = [];
    var read_ok = false;
    {
        var content: u8[>..] = [];
        read_ok = read_file(path, content);
        if read_ok {
            format(script_buf, content);
        }
    }
    if !read_ok {
        print("gosh: source: ", path, ": No such file or directory");
        return 1;
    }
    return execute_script(state, script_buf);
}
