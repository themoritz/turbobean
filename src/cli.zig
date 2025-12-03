const std = @import("std");

pub const colors = struct {
    const CSI = "\x1b[";
    pub const RESET = CSI ++ "0m";

    pub const BOLD = CSI ++ "1m";
    pub const DIM = CSI ++ "2m";
    pub const ITALIC = CSI ++ "3m";
    pub const UNDERLINE = CSI ++ "4m";

    pub const BLACK = CSI ++ "30m";
    pub const RED = CSI ++ "31m";
    pub const GREEN = CSI ++ "32m";
    pub const YELLOW = CSI ++ "33m";
    pub const BLUE = CSI ++ "34m";
    pub const MAGENTA = CSI ++ "35m";
    pub const CYAN = CSI ++ "36m";
    pub const WHITE = CSI ++ "37m";
    pub const BGRED = CSI ++ "41m";
    pub const BGGREEN = CSI ++ "42m";
};

pub fn printHelp() void {
    std.debug.print(
        \\{[r]s}{[b]s}Turbobean{[r]s} is a fast Beancount implementation.
        \\
        \\{[b]s}Usage:{[r]s} turbobean {[magenta]s}<command>{[r]s} {[d]s}[...args]{[r]s}
        \\
        \\{[b]s}Commands:{[r]s}
        \\  {[b]s}{[magenta]s}lsp{[r]s}                  Start the LSP server
        \\  {[b]s}{[magenta]s}serve{[r]s}  {[d]s}main.bean{[r]s}     Start web server for a Beancount project
        \\  {[b]s}{[magenta]s}tree{[r]s}   {[d]s}file.bean{[r]s}     Show final balances of all accounts as a tree
        \\
        \\Learn more: {[blue]s}https://github.com/themoritz/turbobean{[r]s}
        \\
    , .{
        .b = colors.BOLD,
        .d = colors.DIM,
        .r = colors.RESET,
        .magenta = colors.MAGENTA,
        .blue = colors.BLUE,
    });
}

pub fn printUnknownCommand() void {
    std.debug.print(
        "Unknown command. Run {[b]s}turbobean -h{[r]s} for help\n",
        .{ .b = colors.BOLD, .r = colors.RESET },
    );
}

pub fn printMissingFileArgument() void {
    std.debug.print(
        "Missing file argument. Run {[b]s}turbobean -h{[r]s} for help\n",
        .{ .b = colors.BOLD, .r = colors.RESET },
    );
}
