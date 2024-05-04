const std = @import("std");
const Test = @import("./test.zig");
const zkcp = @import("./zkcp.zig");
pub fn main() !void {
    var v = zkcp._itimediff(1, 2);
    if (v != -1) {
        std.log.err("_itimediff(1,2) = {}", .{v});
        return;
    }
    v = zkcp._itimediff(2, 1);
    if (v != 1) {
        std.log.err("_itimediff(2,1) = {}", .{v});
        return;
    }
    v = zkcp._itimediff(0xff_ff_ff_ff, 0);
    if (v != -1) {
        std.log.err("_itimediff(0xff_ff_ff_ff,0) = {}", .{v});
        return;
    }
    try Test.Test(0);
    try Test.Test(1);
    try Test.Test(2);
}
