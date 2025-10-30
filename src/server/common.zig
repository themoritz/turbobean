const zts = @import("zts");
const t = @import("templates.zig");

pub fn renderPlotArea(operating_currencies: []const []const u8, out: anytype) !void {
    try zts.writeHeader(t.plot, out);
    try zts.write(t.plot, "settings", out);
    for (operating_currencies) |cur| {
        try zts.print(t.plot, "operating_currency", .{
            .currency = cur,
        }, out);
    }
    try zts.write(t.plot, "end_conversions", out);
    try zts.write(t.plot, "plot", out);
}
