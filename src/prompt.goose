import std;
import gosh_types;
import gosh_os;

// Format prompt for interactive display
// Returns visible character count (excluding ANSI color escapes)
fn format_prompt(state: const ShellState&, out: u8[>..]&) -> i32 {
    out.clear();

    // 1. User & Host (Bold Green / Cyan)
    out.append("\033[1;32m");
    if state.user.len > 0 {
        out.append(state.user);
    } else {
        out.append("user");
    }
    out.append("\033[0m@\033[1;36m");
    if state.hostname.len > 0 {
        out.append(state.hostname);
    } else {
        out.append("gosh");
    }
    out.append("\033[0m:");

    var visible_len = (if state.user.len > 0 { state.user.len } else { 4 }) +
                      1 +
                      (if state.hostname.len > 0 { state.hostname.len } else { 4 }) +
                      1;

    // 2. Directory (with ~ replacement for HOME)
    out.append("\033[1;34m");
    if state.home.len > 0 && starts_with(state.cwd, state.home) {
        out.push('~');
        visible_len++;
        if state.cwd.len > state.home.len {
            let rel = state.cwd[state.home.len..];
            out.append(rel);
            visible_len += rel.len;
        }
    } else {
        out.append(state.cwd);
        visible_len += state.cwd.len;
    }
    out.append("\033[0m");

    // 3. Git branch (if in repo)
    var git_buf: u8[256] = [0; 256];
    let glen = gosh_get_git_branch(git_buf);
    if glen > 0 {
        out.append(" \033[1;33m(git:");
        out.append(git_buf[..glen]);
        out.append(")\033[0m");
        visible_len += 1 + 5 + glen + 1; // " (git:branch)"
    }

    // 4. Prompt symbol: Green ❯ (or $) if success, Red if error
    if state.last_status == 0 {
        out.append(" \033[1;32m❯\033[0m ");
    } else {
        out.append(" \033[1;31m❯\033[0m ");
    }
    visible_len += 3; // " ❯ "

    return visible_len as i32;
}
