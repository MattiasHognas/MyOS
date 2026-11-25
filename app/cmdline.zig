//! Splitting a command line into arguments, for the shell.
//!
//! Words are separated by spaces. Quotes keep spaces in a word: inside
//! single quotes every character stands for itself; inside double quotes a
//! backslash still makes the next character literal. Outside quotes a
//! backslash does the same. Quoted and unquoted parts next to each other
//! make one word (`a"b c"d` is `ab cd`), and `''` is an empty argument.
//!
//! No variables, no globbing, no operators. Tested on the host.

pub const Error = error{
    /// A quote that is never closed, or a backslash at the very end.
    Unterminated,
    /// More arguments than there is room for.
    TooManyArguments,
    /// The arguments with their terminating NULs do not fit in the buffer.
    TooLong,
};

/// Split `line` into arguments. The words are written to `storage`, each
/// followed by a NUL, and a pointer to each is put in `argv`, followed by a
/// null pointer (so `argv` needs room for one more than the arguments).
/// Returns the number of arguments.
pub fn split(line: []const u8, storage: []u8, argv: []?[*:0]const u8) Error!usize {
    var used: usize = 0;
    var argc: usize = 0;
    var i: usize = 0;
    while (true) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i == line.len) break;
        if (argc + 1 >= argv.len) return error.TooManyArguments;

        const start = used;
        var quote: u8 = 0; // the quote character we are inside, or 0
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (quote == 0 and c == ' ') break;
            if (quote == 0 and (c == '\'' or c == '"')) {
                quote = c;
                continue;
            }
            if (quote != 0 and c == quote) {
                quote = 0;
                continue;
            }
            var out = c;
            if (c == '\\' and quote != '\'') {
                i += 1;
                if (i == line.len) return error.Unterminated;
                out = line[i];
            }
            if (used == storage.len) return error.TooLong;
            storage[used] = out;
            used += 1;
        }
        if (quote != 0) return error.Unterminated;
        if (used == storage.len) return error.TooLong;
        storage[used] = 0;
        used += 1;
        argv[argc] = @ptrCast(storage[start..].ptr);
        argc += 1;
    }
    if (argv.len == 0) return error.TooManyArguments;
    argv[argc] = null;
    return argc;
}
