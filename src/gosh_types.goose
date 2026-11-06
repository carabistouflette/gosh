import std;

let TOKEN_EOF = 0;
let TOKEN_WORD = 1;
let TOKEN_PIPE = 2;          // |
let TOKEN_AND = 3;           // &&
let TOKEN_OR = 4;            // ||
let TOKEN_SEMI = 5;          // ;
let TOKEN_AMP = 6;           // &
let TOKEN_REDIR_IN = 7;      // <
let TOKEN_REDIR_OUT = 8;     // >
let TOKEN_REDIR_APP = 9;     // >>
let TOKEN_REDIR_ERR = 10;    // 2>
let TOKEN_REDIR_ERR_APP = 11;// 2>>
let TOKEN_REDIR_BOTH = 12;   // &>
let TOKEN_REDIR_E2O = 13;    // 2>&1
let TOKEN_NEWLINE = 14;      // \n
let TOKEN_LPAREN = 15;       // (
let TOKEN_RPAREN = 16;       // )
let TOKEN_LBRACE = 17;       // {
let TOKEN_RBRACE = 18;       // }

// Keywords
let TOKEN_IF = 20;
let TOKEN_THEN = 21;
let TOKEN_ELIF = 22;
let TOKEN_ELSE = 23;
let TOKEN_FI = 24;
let TOKEN_WHILE = 25;
let TOKEN_UNTIL = 26;
let TOKEN_FOR = 27;
let TOKEN_IN = 28;
let TOKEN_DO = 29;
let TOKEN_DONE = 30;
let TOKEN_FUNCTION = 31;

struct Token {
    kind: i32 = 0,
    text: u8[..128] = [],
}

struct Redirection {
    kind: i32 = 0,
    target: u8[..128] = [],
}

struct Command {
    argv: u8[..128][..16] = [],
    arg_count: i32 = 0,
    redirs: Redirection[..4] = [],
    redir_count: i32 = 0,
    background: bool = false,
    is_assignment: bool = false,
    assign_var: u8[..64] = [],
    assign_val: u8[..256] = [],
}

// op_after: 0 = none, 1 = &&, 2 = ||, 3 = ; or newline, 4 = &
let OP_NONE = 0;
let OP_AND = 1;
let OP_OR = 2;
let OP_SEMI = 3;
let OP_BG = 4;

struct Pipeline {
    cmds: Command[..4] = [],
    cmd_count: i32 = 0,
    op_after: i32 = 0,
}

let STMT_PIPELINE = 1;
let STMT_IF = 2;
let STMT_WHILE = 3;
let STMT_FOR = 4;
let STMT_FUNC = 5;
let STMT_SUBSHELL = 6;

struct Statement {
    kind: i32 = STMT_PIPELINE,
    pipeline: Pipeline = Pipeline {},

    // Compound statements
    cond_text: u8[..256] = [],
    body_text: u8[..512] = [],
    else_text: u8[..256] = [],

    for_var: u8[..32] = [],
    for_words: u8[..128][..16] = [],

    func_name: u8[..32] = [],
    func_body: u8[..512] = [],

    redirs: Redirection[..4] = [],
    op_after: i32 = OP_NONE,
}

struct ShellVar {
    name: u8[..64] = [],
    val: u8[..512] = [],
    exported: bool = false,
}

struct ShellAlias {
    name: u8[..32] = [],
    val: u8[..128] = [],
}

struct ShellFunc {
    name: u8[..32] = [],
    body: u8[..512] = [],
}

struct JobProcess {
    pid: i32 = 0,
    event: i32 = 0, // gosh_os event ABI; continued processes are runnable
    status: i32 = 0,
}

struct ShellJob {
    id: i32 = 0,
    pid: i32 = 0,
    processes: JobProcess[..4] = [],
    event: i32 = 0,
    status: i32 = 0,
    cmd: u8[..64] = [],
}

struct ShellState {
    vars: ShellVar[..128] = [],
    var_count: i32 = 0,

    aliases: ShellAlias[..32] = [],
    alias_count: i32 = 0,

    funcs: ShellFunc[..32] = [],
    func_count: i32 = 0,

    jobs: ShellJob[..16] = [],
    job_count: i32 = 0,
    last_bg_pid: i32 = 0,

    last_status: i32 = 0,
    pid: i32 = 0,
    running: bool = true,
    interactive: bool = false,

    emacs_mode: bool = true,
    vi_mode: bool = false,
    syntax_highlight: bool = true,
    autosuggest: bool = true,

    cwd: u8[..512] = [],
    home: u8[..256] = [],
    user: u8[..64] = [],
    hostname: u8[..64] = [],

    script_name: u8[..128] = [],
    script_args: u8[..128][..16] = [],

    hist_lines: u8[..256][..128] = [],
    hist_count: i32 = 0,
}
