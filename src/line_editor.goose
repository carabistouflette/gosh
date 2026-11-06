import std;
import gosh_types;
import gosh_os;
import prompt;
import completion;
import os;

let KEY_ENTER = 10;
let KEY_CTRL_A = 1;
let KEY_CTRL_B = 2;
let KEY_CTRL_C = 3;
let KEY_CTRL_D = 4;
let KEY_CTRL_E = 5;
let KEY_CTRL_F = 6;
let KEY_CTRL_K = 11;
let KEY_CTRL_L = 12;
let KEY_CTRL_R = 18;
let KEY_CTRL_U = 21;
let KEY_CTRL_W = 23;
let KEY_TAB = 9;
let KEY_BACKSPACE = 127;
let KEY_ESC = 27;

let KEY_UP = 1001;
let KEY_DOWN = 1002;
let KEY_RIGHT = 1003;
let KEY_LEFT = 1004;
let KEY_HOME = 1005;
let KEY_END = 1006;
let KEY_DELETE = 1007;
let KEY_ALT_B = 1008;
let KEY_ALT_F = 1009;
let KEY_ALT_BS = 1010;

// Read one key or escape sequence
fn read_key() -> i32 {
    let b = gosh_term_read_byte(0);
    if b != KEY_ESC {
        return b;
    }

    // Escape sequence
    let b2 = gosh_term_read_byte(0);
    if b2 == '[' {
        let b3 = gosh_term_read_byte(0);
        if b3 == 'A' { return KEY_UP; }
        if b3 == 'B' { return KEY_DOWN; }
        if b3 == 'C' { return KEY_RIGHT; }
        if b3 == 'D' { return KEY_LEFT; }
        if b3 == 'H' { return KEY_HOME; }
        if b3 == 'F' { return KEY_END; }
        if b3 == '3' {
            let b4 = gosh_term_read_byte(0); // ~
            return KEY_DELETE;
        }
        if b3 == '1' {
            let b4 = gosh_term_read_byte(0); // ;
            let b5 = gosh_term_read_byte(0); // 5
            let b6 = gosh_term_read_byte(0); // C/D
            if b6 == 'C' { return KEY_ALT_F; }
            if b6 == 'D' { return KEY_ALT_B; }
        }
        return KEY_ESC;
    }
    if b2 == 'b' { return KEY_ALT_B; }
    if b2 == 'f' { return KEY_ALT_F; }
    if b2 == 127 { return KEY_ALT_BS; }
    return KEY_ESC;
}

// Find suggestion from history
fn find_autosuggestion(state: const ShellState&, input_line: const u8[:], suggestion: u8[..256]&) -> bool {
    suggestion.clear();
    if input_line.len == 0 || state.hist_count == 0 { return false; }

    for i in state.hist_count {
        let idx = state.hist_count - 1 - i;
        let hist = state.hist_lines[idx];
        if hist.len > input_line.len && starts_with(hist, input_line) {
            format(suggestion, hist[input_line.len..]);
            return true;
        }
    }
    return false;
}

// Check if first word is valid executable, builtin, or alias
fn is_valid_cmd(cmd: const u8[:]) -> bool {
    if is_builtin(cmd) { return true; }
    if gosh_is_executable(cmd) != 0 { return true; }

    var path_env: u8[>..] = [];
    if env("PATH", path_env) {
        each_split(path_env, ':') {
            if it.len > 0 {
                var full_path: u8[>..] = [];
                format(full_path, it, "/", cmd);
                if gosh_is_executable(full_path) != 0 {
                    return true from is_valid_cmd;
                }
            }
        };
    }
    return false;
}

// Syntax highlight the buffer to stdout
fn render_highlighted(buf: const u8[:], out: u8[>..]&) {
    if buf.len == 0 { return; }

    var i = 0;
    var word_start = 0;
    var is_first_word = true;
    var in_single_quote = false;
    var in_double_quote = false;

    while i < buf.len {
        let c = buf[i];

        // Quotes
        if c == '\'' && !in_double_quote {
            in_single_quote = !in_single_quote;
            out.append("\033[33m"); // Yellow
            out.push(c);
            if !in_single_quote { out.append("\033[0m"); }
            i++;
            continue;
        }
        if c == '"' && !in_single_quote {
            in_double_quote = !in_double_quote;
            out.append("\033[33m"); // Yellow
            out.push(c);
            if !in_double_quote { out.append("\033[0m"); }
            i++;
            continue;
        }

        if in_single_quote || in_double_quote {
            out.push(c);
            i++;
            continue;
        }

        // Variable $
        if c == '$' {
            out.append("\033[35m"); // Magenta
            out.push(c);
            i++;
            while i < buf.len && (ascii::is_alnum(buf[i]) || buf[i] == '_' || buf[i] == '?' || buf[i] == '{' || buf[i] == '}') {
                out.push(buf[i]);
                i++;
            }
            out.append("\033[0m");
            continue;
        }

        // Operators: |, &, ;, <, >
        if c == '|' || c == '&' || c == ';' || c == '<' || c == '>' {
            out.append("\033[1;34m"); // Bold Blue
            out.push(c);
            if i + 1 < buf.len && (buf[i + 1] == c || buf[i + 1] == '&' || buf[i + 1] == '>') {
                out.push(buf[i + 1]);
                i++;
            }
            out.append("\033[0m");
            is_first_word = true; // Next word is a command!
            i++;
            continue;
        }

        // Whitespace
        if c == ' ' || c == '\t' {
            out.push(c);
            i++;
            continue;
        }

        // Word (command or argument)
        word_start = i;
        while i < buf.len && buf[i] != ' ' && buf[i] != '\t' && buf[i] != '|' && buf[i] != '&' && buf[i] != ';' && buf[i] != '<' && buf[i] != '>' && buf[i] != '\'' && buf[i] != '"' {
            i++;
        }
        let w = buf[word_start..i];

        if is_first_word {
            // First word: check validity
            if is_valid_cmd(w) {
                out.append("\033[1;32m"); // Bold Green
            } else {
                out.append("\033[1;31m"); // Bold Red
            }
            out.append(w);
            out.append("\033[0m");
            is_first_word = false;
        } else if starts_with(w, "-") {
            // Flags
            out.append("\033[36m"); // Cyan
            out.append(w);
            out.append("\033[0m");
        } else {
            // Normal argument
            out.append(w);
        }
    }
}

// Interactive reverse history search
fn interactive_reverse_search(state: const ShellState&, result: u8[..256]&) -> bool {
    var query: u8[..64] = [];
    var matched_line: u8[..256] = [];

    loop {
        // Redraw reverse-i-search prompt
        var line: u8[>..] = [];
        line.append("\r\033[K(reverse-i-search)`");
        line.append(query);
        line.append("': ");
        line.append(matched_line);
        write_stdout(line);
        flush_stdout();

        let k = read_key();
        if k == KEY_CTRL_C || k == KEY_ESC {
            write_stdout("\n");
            return false;
        }
        if k == KEY_ENTER {
            write_stdout("\n");
            result.clear();
            format(result, matched_line);
            return true;
        }
        if k == KEY_BACKSPACE || k == 8 {
            if query.len > 0 {
                query.pop();
            }
        } else if k >= 32 && k <= 126 {
            if query.len < 64 {
                query.push(k as u8);
            }
        }

        // Search backward in history
        matched_line.clear();
        if query.len > 0 {
            for i in state.hist_count {
                let idx = state.hist_count - 1 - i;
                if find(state.hist_lines[idx], query) >= 0 {
                    format(matched_line, state.hist_lines[idx]);
                    break;
                }
            }
        }
    }
}

// Read an interactive command line with syntax highlighting, autosuggestions, completion
fn read_interactive_line(state: ShellState&, out_line: u8[..512]&) -> bool {
    out_line.clear();

    if gosh_term_isatty(0) == 0 {
        // Not a TTY: fall back to plain read_line
        var line_buf: u8[>..] = [];
        if read_line(line_buf) {
            format(out_line, line_buf);
            return true;
        }
        return false;
    }

    gosh_term_enable_raw(0);

    var prompt_text: u8[>..] = [];
    let prompt_len = format_prompt(state, prompt_text);
    write_stdout(prompt_text);
    flush_stdout();

    var buf: u8[..512] = [];
    var cursor = 0;
    var hist_index = state.hist_count; // bottom
    var saved_bottom: u8[..512] = [];

    // Redraw function: clears current line, draws prompt, highlighted buffer, and autosuggestion
    fn redraw() {
        var render_buf: u8[>..] = [];
        render_buf.append("\r\033[K"); // return to col 0 and clear line
        render_buf.append(prompt_text);

        // Highlight buffer
        render_highlighted(buf, render_buf);

        // Autosuggestion
        var suggest: u8[..256] = [];
        if state.autosuggest && cursor == buf.len && find_autosuggestion(state, buf, suggest) {
            render_buf.append("\033[90m"); // Gray ghost text
            render_buf.append(suggest);
            render_buf.append("\033[0m");
        }

        // Move cursor to proper column: prompt_len + cursor + 1
        var move_cmd: u8[>..] = [];
        format(move_cmd, "\r\033[", prompt_len + cursor, "C");
        render_buf.append(move_cmd);

        write_stdout(render_buf);
        flush_stdout();
    }

    loop {
        let k = read_key();

        if k == KEY_CTRL_D {
            if buf.len == 0 {
                gosh_term_disable_raw(0);
                write_stdout("\n");
                return false; // EOF
            }
            if cursor < buf.len {
                remove_at(buf, cursor);
                redraw();
            }
            continue;
        }

        if k == KEY_CTRL_C {
            gosh_term_disable_raw(0);
            write_stdout("^C\n");
            out_line.clear();
            return true;
        }

        if k == KEY_CTRL_L {
            write_stdout("\033[2J\033[H"); // clear screen
            redraw();
            continue;
        }

        if k == KEY_CTRL_R {
            var searched: u8[..256] = [];
            if interactive_reverse_search(state, searched) {
                buf.clear();
                format(buf, searched);
                cursor = buf.len;
            }
            write_stdout(prompt_text);
            redraw();
            continue;
        }

        if k == KEY_ENTER {
            write_stdout("\n");
            flush_stdout();
            gosh_term_disable_raw(0);

            // Multiline check: open single quote, double quote, or trailing backslash
            var single_q = false;
            var double_q = false;
            for i in buf.len {
                let c = buf[i];
                if c == '\'' && !double_q { single_q = !single_q; }
                if c == '"' && !single_q { double_q = !double_q; }
            }
            var trailing_bs = (buf.len > 0 && buf[buf.len - 1] == '\\');

            if single_q || double_q || trailing_bs {
                if trailing_bs { buf.pop(); }
                buf.push('\n');

                // Read continuation line
                write_stdout("> ");
                flush_stdout();
                var cont: u8[>..] = [];
                if read_line(cont) {
                    format(buf, cont);
                }
            }

            format(out_line, buf);
            return true;
        }

        // Backspace
        if k == KEY_BACKSPACE || k == 8 {
            if cursor > 0 {
                cursor--;
                remove_at(buf, cursor);
                redraw();
            }
            continue;
        }

        // Delete
        if k == KEY_DELETE {
            if cursor < buf.len {
                remove_at(buf, cursor);
                redraw();
            }
            continue;
        }

        // Left Arrow
        if k == KEY_LEFT || k == KEY_CTRL_B {
            if cursor > 0 {
                cursor--;
                redraw();
            }
            continue;
        }

        // Right Arrow: if at end, accepts autosuggestion!
        if k == KEY_RIGHT || k == KEY_CTRL_F {
            if cursor == buf.len {
                var suggest: u8[..256] = [];
                if find_autosuggestion(state, buf, suggest) {
                    format(buf, suggest);
                    cursor = buf.len;
                    redraw();
                    continue;
                }
            }
            if cursor < buf.len {
                cursor++;
                redraw();
            }
            continue;
        }

        // Home
        if k == KEY_HOME || k == KEY_CTRL_A {
            cursor = 0;
            redraw();
            continue;
        }

        // End
        if k == KEY_END || k == KEY_CTRL_E {
            // Also accepts autosuggestion
            var suggest: u8[..256] = [];
            if cursor == buf.len && find_autosuggestion(state, buf, suggest) {
                format(buf, suggest);
            }
            cursor = buf.len;
            redraw();
            continue;
        }

        // Alt+B: word back
        if k == KEY_ALT_B {
            while cursor > 0 && buf[cursor - 1] == ' ' { cursor--; }
            while cursor > 0 && buf[cursor - 1] != ' ' { cursor--; }
            redraw();
            continue;
        }

        // Alt+F: word forward
        if k == KEY_ALT_F {
            while cursor < buf.len && buf[cursor] != ' ' { cursor++; }
            while cursor < buf.len && buf[cursor] == ' ' { cursor++; }
            redraw();
            continue;
        }

        // Ctrl+W / Alt+Backspace: delete word backward
        if k == KEY_CTRL_W || k == KEY_ALT_BS {
            let old_cur = cursor;
            while cursor > 0 && buf[cursor - 1] == ' ' { cursor--; }
            while cursor > 0 && buf[cursor - 1] != ' ' { cursor--; }
            let del_count = old_cur - cursor;
            for i in del_count {
                remove_at(buf, cursor);
            }
            redraw();
            continue;
        }

        // Ctrl+K: kill to end of line
        if k == KEY_CTRL_K {
            let count = buf.len - cursor;
            for i in count {
                buf.pop();
            }
            redraw();
            continue;
        }

        // Ctrl+U: kill to start of line
        if k == KEY_CTRL_U {
            for i in cursor {
                remove_at(buf, 0);
            }
            cursor = 0;
            redraw();
            continue;
        }

        // Up Arrow: History back
        if k == KEY_UP {
            if hist_index == state.hist_count {
                saved_bottom.clear();
                format(saved_bottom, buf);
            }
            if hist_index > 0 {
                hist_index--;
                buf.clear();
                format(buf, state.hist_lines[hist_index]);
                cursor = buf.len;
                redraw();
            }
            continue;
        }

        // Down Arrow: History forward
        if k == KEY_DOWN {
            if hist_index < state.hist_count {
                hist_index++;
                buf.clear();
                if hist_index == state.hist_count {
                    format(buf, saved_bottom);
                } else {
                    format(buf, state.hist_lines[hist_index]);
                }
                cursor = buf.len;
                redraw();
            }
            continue;
        }

        // Tab: Completion or accept suggestion
        if k == KEY_TAB {
            var suggest: u8[..256] = [];
            if cursor == buf.len && find_autosuggestion(state, buf, suggest) {
                format(buf, suggest);
                cursor = buf.len;
                redraw();
                continue;
            }

            var completions: u8[..256][..64] = [];
            find_completions(state, buf[..cursor], completions);

            if completions.len == 1 {
                // Single completion: replace/complete current word
                let comp = completions[0];
                let context = completion_context(buf[..cursor]);
                let word_start = context.word_start;
                let typed_word = buf[word_start..cursor];
                if starts_with(comp, typed_word) {
                    let addition = comp[typed_word.len..];
                    for ch in addition {
                        insert_at(buf, cursor, ch);
                        cursor++;
                    }
                    if !ends_with(comp, "/") {
                        insert_at(buf, cursor, ' ');
                        cursor++;
                    }
                }
                redraw();
            } else if completions.len > 1 {
                // Show completion menu
                write_stdout("\n");
                var col = 0;
                for c in completions {
                    var item: u8[>..] = [];
                    item.append(c);
                    while item.len < 24 { item.push(' '); }
                    write_stdout(item);
                    col += 24;
                    if col >= 72 {
                        write_stdout("\n");
                        col = 0;
                    }
                }
                if col > 0 { write_stdout("\n"); }
                write_stdout(prompt_text);
                redraw();
            }
            continue;
        }

        // Regular character insertion (ASCII or UTF-8 bytes)
        if (k >= 32 && k <= 126) || k >= 128 {
            if buf.len < 512 {
                insert_at(buf, cursor, k as u8);
                cursor++;
                redraw();
            }
            continue;
        }
    }
}
