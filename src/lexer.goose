import std;
import gosh_types;

fn is_ident_char(c: u8) -> bool {
    ascii::is_alnum(c) || c == '_'
}

fn is_delim(c: u8) -> bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
    c == '|' || c == '&' || c == ';' || c == '<' || c == '>' ||
    c == '(' || c == ')' || c == '{' || c == '}'
}

fn tokenize_line(line: const u8[:], tokens: Token[..64]&) -> i32 {
    tokens.clear();
    var i = 0;
    let len = line.len;

    while i < len {
        let c = line[i];

        // Skip spaces and tabs
        if c == ' ' || c == '\t' || c == '\r' {
            i++;
            continue;
        }

        // Comment
        if c == '#' {
            while i < len && line[i] != '\n' {
                i++;
            }
            continue;
        }

        // Newline
        if c == '\n' {
            var tok = Token { kind: TOKEN_NEWLINE };
            format(tok.text, "\n");
            tokens.push(tok);
            i++;
            continue;
        }

        // Semicolon
        if c == ';' {
            var tok = Token { kind: TOKEN_SEMI };
            format(tok.text, ";");
            tokens.push(tok);
            i++;
            continue;
        }

        // Pipe or OR
        if c == '|' {
            if i + 1 < len && line[i + 1] == '|' {
                var tok = Token { kind: TOKEN_OR };
                format(tok.text, "||");
                tokens.push(tok);
                i += 2;
            } else {
                var tok = Token { kind: TOKEN_PIPE };
                format(tok.text, "|");
                tokens.push(tok);
                i++;
            }
            continue;
        }

        // Ampersand or AND
        if c == '&' {
            if i + 1 < len && line[i + 1] == '&' {
                var tok = Token { kind: TOKEN_AND };
                format(tok.text, "&&");
                tokens.push(tok);
                i += 2;
            } else if i + 1 < len && line[i + 1] == '>' {
                var tok = Token { kind: TOKEN_REDIR_BOTH };
                format(tok.text, "&>");
                tokens.push(tok);
                i += 2;
            } else {
                var tok = Token { kind: TOKEN_AMP };
                format(tok.text, "&");
                tokens.push(tok);
                i++;
            }
            continue;
        }

        // Redirect IN
        if c == '<' {
            var tok = Token { kind: TOKEN_REDIR_IN };
            format(tok.text, "<");
            tokens.push(tok);
            i++;
            continue;
        }

        // Redirect OUT or APPEND
        if c == '>' {
            if i + 1 < len && line[i + 1] == '>' {
                var tok = Token { kind: TOKEN_REDIR_APP };
                format(tok.text, ">>");
                tokens.push(tok);
                i += 2;
            } else if i + 1 < len && line[i + 1] == '&' && i + 2 < len && line[i + 2] == '2' {
                var tok = Token { kind: TOKEN_REDIR_E2O };
                format(tok.text, ">&2");
                tokens.push(tok);
                i += 3;
            } else {
                var tok = Token { kind: TOKEN_REDIR_OUT };
                format(tok.text, ">");
                tokens.push(tok);
                i++;
            }
            continue;
        }

        // 2> or 2>> or 2>&1
        if c == '2' && i + 1 < len && line[i + 1] == '>' {
            if i + 2 < len && line[i + 2] == '>' {
                var tok = Token { kind: TOKEN_REDIR_ERR_APP };
                format(tok.text, "2>>");
                tokens.push(tok);
                i += 3;
            } else if i + 3 < len && line[i + 2] == '&' && line[i + 3] == '1' {
                var tok = Token { kind: TOKEN_REDIR_E2O };
                format(tok.text, "2>&1");
                tokens.push(tok);
                i += 4;
            } else {
                var tok = Token { kind: TOKEN_REDIR_ERR };
                format(tok.text, "2>");
                tokens.push(tok);
                i += 2;
            }
            continue;
        }

        // Parentheses and Braces
        if c == '(' {
            var tok = Token { kind: TOKEN_LPAREN };
            format(tok.text, "(");
            tokens.push(tok);
            i++;
            continue;
        }
        if c == ')' {
            var tok = Token { kind: TOKEN_RPAREN };
            format(tok.text, ")");
            tokens.push(tok);
            i++;
            continue;
        }
        if c == '{' {
            var tok = Token { kind: TOKEN_LBRACE };
            format(tok.text, "{");
            tokens.push(tok);
            i++;
            continue;
        }
        if c == '}' {
            var tok = Token { kind: TOKEN_RBRACE };
            format(tok.text, "}");
            tokens.push(tok);
            i++;
            continue;
        }

        // Word (includes quotes, escapes, variables, $((...)), $(...), `...`)
        var tok = Token { kind: TOKEN_WORD };
        while i < len {
            let ch = line[i];

            // Arithmetic $((...))
            if ch == '$' && i + 2 < len && line[i + 1] == '(' && line[i + 2] == '(' {
                tok.text.push('$');
                tok.text.push('(');
                tok.text.push('(');
                i += 3;
                var depth = 0;
                while i < len {
                    if line[i] == '(' { depth++; }
                    else if line[i] == ')' {
                        if depth == 0 { break; }
                        depth--;
                    }
                    tok.text.push(line[i]);
                    i++;
                }
                if i + 1 < len && line[i] == ')' && line[i + 1] == ')' {
                    tok.text.push(')');
                    tok.text.push(')');
                    i += 2;
                }
                continue;
            }

            // Command substitution $(...)
            if ch == '$' && i + 1 < len && line[i + 1] == '(' {
                tok.text.push('$');
                tok.text.push('(');
                i += 2;
                var depth = 1;
                while i < len && depth > 0 {
                    if line[i] == '(' { depth++; }
                    else if line[i] == ')' {
                        depth--;
                        if depth == 0 { tok.text.push(')'); i++; break; }
                    }
                    tok.text.push(line[i]);
                    i++;
                }
                continue;
            }

            // Command substitution `...`
            if ch == '`' {
                tok.text.push('`');
                i++;
                while i < len && line[i] != '`' {
                    tok.text.push(line[i]);
                    i++;
                }
                if i < len && line[i] == '`' {
                    tok.text.push('`');
                    i++;
                }
                continue;
            }

            // Variable ${...}
            if ch == '$' && i + 1 < len && line[i + 1] == '{' {
                tok.text.push('$');
                tok.text.push('{');
                i += 2;
                while i < len && line[i] != '}' {
                    tok.text.push(line[i]);
                    i++;
                }
                if i < len && line[i] == '}' {
                    tok.text.push('}');
                    i++;
                }
                continue;
            }

            if is_delim(ch) {
                break;
            }
            if ch == '\\' {
                if i + 1 < len {
                    tok.text.push(line[i + 1]);
                    i += 2;
                } else {
                    tok.text.push(ch);
                    i++;
                }
                continue;
            }
            if ch == '\'' {
                // Single quote: preserve quotes so expansion engine knows not to expand
                tok.text.push('\'');
                i++;
                while i < len && line[i] != '\'' {
                    tok.text.push(line[i]);
                    i++;
                }
                if i < len && line[i] == '\'' {
                    tok.text.push('\'');
                    i++;
                }
                continue;
            }
            if ch == '"' {
                // Double quote: preserve quotes so expansion engine knows not to glob
                tok.text.push('"');
                i++;
                while i < len && line[i] != '"' {
                    if line[i] == '\\' && i + 1 < len {
                        let next = line[i + 1];
                        if next == '"' || next == '\\' || next == '$' || next == '`' {
                            tok.text.push('\\');
                            tok.text.push(next);
                            i += 2;
                            continue;
                        }
                    }
                    tok.text.push(line[i]);
                    i++;
                }
                if i < len && line[i] == '"' {
                    tok.text.push('"');
                    i++;
                }
                continue;
            }

            tok.text.push(ch);
            i++;
        }

        // Keyword recognition
        if tok.text == "if" { tok.kind = TOKEN_IF; }
        else if tok.text == "then" { tok.kind = TOKEN_THEN; }
        else if tok.text == "elif" { tok.kind = TOKEN_ELIF; }
        else if tok.text == "else" { tok.kind = TOKEN_ELSE; }
        else if tok.text == "fi" { tok.kind = TOKEN_FI; }
        else if tok.text == "while" { tok.kind = TOKEN_WHILE; }
        else if tok.text == "until" { tok.kind = TOKEN_UNTIL; }
        else if tok.text == "for" { tok.kind = TOKEN_FOR; }
        else if tok.text == "in" { tok.kind = TOKEN_IN; }
        else if tok.text == "do" { tok.kind = TOKEN_DO; }
        else if tok.text == "done" { tok.kind = TOKEN_DONE; }
        else if tok.text == "function" { tok.kind = TOKEN_FUNCTION; }

        tokens.push(tok);
    }

    var eof_tok = Token { kind: TOKEN_EOF };
    tokens.push(eof_tok);
    return tokens.len as i32;
}
