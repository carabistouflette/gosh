import std;
import gosh_types;

fn is_redir_token(kind: i32) -> bool {
    kind == TOKEN_REDIR_IN || kind == TOKEN_REDIR_OUT ||
    kind == TOKEN_REDIR_APP || kind == TOKEN_REDIR_ERR ||
    kind == TOKEN_REDIR_ERR_APP || kind == TOKEN_REDIR_BOTH ||
    kind == TOKEN_REDIR_E2O
}

fn parse_statements(tokens: const Token[..64]&, stmts: Statement[..8]&) {
    stmts.clear();
    var pos = 0;
    let n = tokens.len;

    while pos < n {
        let tok = tokens[pos];

        // Skip newlines or semicolons at top level
        if tok.kind == TOKEN_NEWLINE || tok.kind == TOKEN_SEMI || tok.kind == TOKEN_EOF {
            pos++;
            continue;
        }

        // 1. IF statement: if COND; then THEN; [else ELSE;] fi
        if tok.kind == TOKEN_IF {
            pos++;
            var stmt = Statement { kind: STMT_IF };

            // Collect condition tokens until 'then'
            while pos < n && tokens[pos].kind != TOKEN_THEN && tokens[pos].kind != TOKEN_EOF {
                if stmt.cond_text.len > 0 { stmt.cond_text.push(' '); }
                format(stmt.cond_text, tokens[pos].text);
                pos++;
            }
            if pos < n && tokens[pos].kind == TOKEN_THEN { pos++; }

            // Collect then body until 'else', 'elif', or 'fi'
            while pos < n && tokens[pos].kind != TOKEN_ELSE && tokens[pos].kind != TOKEN_ELIF && tokens[pos].kind != TOKEN_FI && tokens[pos].kind != TOKEN_EOF {
                if tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI {
                    stmt.body_text.push(';');
                    stmt.body_text.push(' ');
                } else {
                    if stmt.body_text.len > 0 && stmt.body_text[stmt.body_text.len - 1] != ' ' {
                        stmt.body_text.push(' ');
                    }
                    format(stmt.body_text, tokens[pos].text);
                }
                pos++;
            }

            // Optional ELSE
            if pos < n && tokens[pos].kind == TOKEN_ELSE {
                pos++;
                while pos < n && tokens[pos].kind != TOKEN_FI && tokens[pos].kind != TOKEN_EOF {
                    if tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI {
                        stmt.else_text.push(';');
                        stmt.else_text.push(' ');
                    } else {
                        if stmt.else_text.len > 0 && stmt.else_text[stmt.else_text.len - 1] != ' ' {
                            stmt.else_text.push(' ');
                        }
                        format(stmt.else_text, tokens[pos].text);
                    }
                    pos++;
                }
            }

            if pos < n && tokens[pos].kind == TOKEN_FI { pos++; }
            while pos < n && is_redir_token(tokens[pos].kind) {
                var r = Redirection { kind: tokens[pos].kind };
                pos++;
                if pos < n && tokens[pos].kind == TOKEN_WORD { format(r.target, tokens[pos].text); pos++; }
                if stmt.redirs.len < 4 { stmt.redirs.push(r); }
            }
            stmts.push(stmt);
            continue;
        }

        // 2. WHILE statement: while COND; do BODY; done
        if tok.kind == TOKEN_WHILE {
            pos++;
            var stmt = Statement { kind: STMT_WHILE };

            while pos < n && tokens[pos].kind != TOKEN_DO && tokens[pos].kind != TOKEN_EOF {
                if stmt.cond_text.len > 0 { stmt.cond_text.push(' '); }
                format(stmt.cond_text, tokens[pos].text);
                pos++;
            }
            if pos < n && tokens[pos].kind == TOKEN_DO { pos++; }

            while pos < n && tokens[pos].kind != TOKEN_DONE && tokens[pos].kind != TOKEN_EOF {
                if tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI {
                    stmt.body_text.push(';');
                    stmt.body_text.push(' ');
                } else {
                    if stmt.body_text.len > 0 && stmt.body_text[stmt.body_text.len - 1] != ' ' {
                        stmt.body_text.push(' ');
                    }
                    format(stmt.body_text, tokens[pos].text);
                }
                pos++;
            }

            if pos < n && tokens[pos].kind == TOKEN_DONE { pos++; }
            while pos < n && is_redir_token(tokens[pos].kind) {
                var r = Redirection { kind: tokens[pos].kind };
                pos++;
                if pos < n && tokens[pos].kind == TOKEN_WORD { format(r.target, tokens[pos].text); pos++; }
                if stmt.redirs.len < 4 { stmt.redirs.push(r); }
            }
            stmts.push(stmt);
            continue;
        }

        // 3. FOR statement: for VAR in WORDS; do BODY; done
        if tok.kind == TOKEN_FOR {
            pos++;
            var stmt = Statement { kind: STMT_FOR };
            if pos < n && tokens[pos].kind == TOKEN_WORD {
                format(stmt.for_var, tokens[pos].text);
                pos++;
            }
            if pos < n && tokens[pos].kind == TOKEN_IN {
                pos++;
                while pos < n && tokens[pos].kind != TOKEN_DO && tokens[pos].kind != TOKEN_SEMI && tokens[pos].kind != TOKEN_NEWLINE && tokens[pos].kind != TOKEN_EOF {
                    if tokens[pos].kind == TOKEN_WORD && stmt.for_words.len < 16 {
                        var w: u8[..128] = [];
                        format(w, tokens[pos].text);
                        stmt.for_words.push(w);
                    }
                    pos++;
                }
            }
            while pos < n && (tokens[pos].kind == TOKEN_SEMI || tokens[pos].kind == TOKEN_NEWLINE) { pos++; }
            if pos < n && tokens[pos].kind == TOKEN_DO { pos++; }

            while pos < n && tokens[pos].kind != TOKEN_DONE && tokens[pos].kind != TOKEN_EOF {
                if tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI {
                    stmt.body_text.push(';');
                    stmt.body_text.push(' ');
                } else {
                    if stmt.body_text.len > 0 && stmt.body_text[stmt.body_text.len - 1] != ' ' {
                        stmt.body_text.push(' ');
                    }
                    format(stmt.body_text, tokens[pos].text);
                }
                pos++;
            }
            if pos < n && tokens[pos].kind == TOKEN_DONE { pos++; }
            while pos < n && is_redir_token(tokens[pos].kind) {
                var r = Redirection { kind: tokens[pos].kind };
                pos++;
                if pos < n && tokens[pos].kind == TOKEN_WORD { format(r.target, tokens[pos].text); pos++; }
                if stmt.redirs.len < 4 { stmt.redirs.push(r); }
            }
            stmts.push(stmt);
            continue;
        }

        // 4. FUNCTION definition: name() { ... } or function name { ... }
        if (tok.kind == TOKEN_WORD && pos + 2 < n && tokens[pos + 1].kind == TOKEN_LPAREN && tokens[pos + 2].kind == TOKEN_RPAREN) ||
           (tok.kind == TOKEN_FUNCTION) {
            var stmt = Statement { kind: STMT_FUNC };
            if tok.kind == TOKEN_FUNCTION {
                pos++;
                if pos < n && tokens[pos].kind == TOKEN_WORD {
                    format(stmt.func_name, tokens[pos].text);
                    pos++;
                }
            } else {
                format(stmt.func_name, tok.text);
                pos += 3; // name ( )
            }

            while pos < n && (tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI) { pos++; }
            if pos < n && tokens[pos].kind == TOKEN_LBRACE {
                pos++;
                var depth = 1;
                while pos < n && depth > 0 && tokens[pos].kind != TOKEN_EOF {
                    if tokens[pos].kind == TOKEN_LBRACE { depth++; }
                    else if tokens[pos].kind == TOKEN_RBRACE {
                        depth--;
                        if depth == 0 { pos++; break; }
                    }
                    if tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI {
                        stmt.func_body.push(';');
                        stmt.func_body.push(' ');
                    } else {
                        if stmt.func_body.len > 0 && stmt.func_body[stmt.func_body.len - 1] != ' ' {
                            stmt.func_body.push(' ');
                        }
                        format(stmt.func_body, tokens[pos].text);
                    }
                    pos++;
                }
            }
            stmts.push(stmt);
            continue;
        }

        // 4b. Subshell: ( ... )
        if tok.kind == TOKEN_LPAREN {
            pos++;
            var stmt = Statement { kind: STMT_SUBSHELL };
            var depth = 1;
            while pos < n && depth > 0 && tokens[pos].kind != TOKEN_EOF {
                if tokens[pos].kind == TOKEN_LPAREN {
                    depth++;
                } else if tokens[pos].kind == TOKEN_RPAREN {
                    depth--;
                    if depth == 0 { pos++; break; }
                }
                if tokens[pos].kind == TOKEN_NEWLINE || tokens[pos].kind == TOKEN_SEMI {
                    stmt.body_text.push(';');
                    stmt.body_text.push(' ');
                } else {
                    if stmt.body_text.len > 0 && stmt.body_text[stmt.body_text.len - 1] != ' ' {
                        stmt.body_text.push(' ');
                    }
                    format(stmt.body_text, tokens[pos].text);
                }
                pos++;
            }
            while pos < n && is_redir_token(tokens[pos].kind) {
                var r = Redirection { kind: tokens[pos].kind };
                pos++;
                if pos < n && tokens[pos].kind == TOKEN_WORD { format(r.target, tokens[pos].text); pos++; }
                if stmt.redirs.len < 4 { stmt.redirs.push(r); }
            }
            if pos < n && (tokens[pos].kind == TOKEN_AND || tokens[pos].kind == TOKEN_OR || tokens[pos].kind == TOKEN_SEMI || tokens[pos].kind == TOKEN_AMP) {
                if tokens[pos].kind == TOKEN_AND { stmt.op_after = OP_AND; }
                else if tokens[pos].kind == TOKEN_OR { stmt.op_after = OP_OR; }
                else if tokens[pos].kind == TOKEN_SEMI { stmt.op_after = OP_SEMI; }
                else if tokens[pos].kind == TOKEN_AMP { stmt.op_after = OP_BG; }
                pos++;
            }
            stmts.push(stmt);
            continue;
        }

        // 5. Regular Pipeline: cmd1 | cmd2 | ... [&& / || / ; / &]
        var pipe = Pipeline {};
        var current_cmd = Command {};

        while pos < n {
            let t = tokens[pos];

            if t.kind == TOKEN_PIPE {
                // End current command, push to pipeline
                current_cmd.arg_count = current_cmd.argv.len as i32;
                current_cmd.redir_count = current_cmd.redirs.len as i32;
                if pipe.cmds.len < 4 {
                    pipe.cmds.push(current_cmd);
                }
                current_cmd = Command {};
                pos++;
                continue;
            }

            if t.kind == TOKEN_AND || t.kind == TOKEN_OR || t.kind == TOKEN_SEMI || t.kind == TOKEN_AMP || t.kind == TOKEN_NEWLINE || t.kind == TOKEN_EOF {
                if t.kind == TOKEN_AND { pipe.op_after = OP_AND; }
                else if t.kind == TOKEN_OR { pipe.op_after = OP_OR; }
                else if t.kind == TOKEN_SEMI || t.kind == TOKEN_NEWLINE { pipe.op_after = OP_SEMI; }
                else if t.kind == TOKEN_AMP { pipe.op_after = OP_BG; current_cmd.background = true; }
                pos++;
                break;
            }

            // Redirection
            if is_redir_token(t.kind) {
                var r = Redirection { kind: t.kind };
                pos++;
                // Target file name
                if pos < n && tokens[pos].kind == TOKEN_WORD {
                    format(r.target, tokens[pos].text);
                    pos++;
                }
                if current_cmd.redirs.len < 4 {
                    current_cmd.redirs.push(r);
                }
                continue;
            }

            // Word / Argument
            if t.kind == TOKEN_WORD {
                // Check if assignment (e.g. FOO=bar) on first word with no command yet
                if current_cmd.argv.len == 0 && !current_cmd.is_assignment {
                    let eq = find(t.text, "=");
                    if eq > 0 && ascii::is_alpha(t.text[0]) {
                        current_cmd.is_assignment = true;
                        format(current_cmd.assign_var, t.text[..eq]);
                        format(current_cmd.assign_val, t.text[eq + 1..]);
                        pos++;
                        continue;
                    }
                }

                if current_cmd.argv.len < 16 {
                    var w: u8[..128] = [];
                    format(w, t.text);
                    current_cmd.argv.push(w);
                }
                pos++;
                continue;
            }

            pos++;
        }

        current_cmd.arg_count = current_cmd.argv.len as i32;
        current_cmd.redir_count = current_cmd.redirs.len as i32;
        if current_cmd.arg_count > 0 || current_cmd.is_assignment || current_cmd.redir_count > 0 {
            pipe.cmds.push(current_cmd);
        }
        pipe.cmd_count = pipe.cmds.len as i32;

        if pipe.cmd_count > 0 {
            var stmt = Statement { kind: STMT_PIPELINE, pipeline: pipe, op_after: pipe.op_after };
            stmts.push(stmt);
        }
    }
}
