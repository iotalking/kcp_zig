const std = @import("std");
const zkcp = @import("./zkcp.zig");
const Kcp = zkcp.Kcp;
const native_endian = zkcp.native_endian;
inline fn iclock64() u64 {
    return @intCast(std.time.milliTimestamp());
}
inline fn iclock() u32 {
    return @intCast(iclock64() & 0xffffffff);
}
inline fn isleep(ms: u64) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}

const DelayPacket = struct {
    _ptr: []u8,
    _ts: u32 = 0,
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator, src: []const u8) !DelayPacket {
        const self: DelayPacket = .{
            .allocator = allocator,
            ._ptr = try allocator.alloc(u8, src.len),
        };
        std.mem.copyForwards(u8, self._ptr, src);
        return self;
    }
    pub fn deinit(self: *DelayPacket) void {
        self.allocator.free(self._ptr);
    }
    pub fn ptr(self: *DelayPacket) []u8 {
        return self._ptr;
    }
    pub fn size(self: *DelayPacket) usize {
        return self._ptr.len;
    }
    pub fn ts(self: *DelayPacket) u32 {
        return self._ts;
    }
    pub fn setTs(self: *DelayPacket, _ts: u32) void {
        self._ts = _ts;
    }
};

const Random = struct {
    size: usize = 0,
    seeds: []usize = undefined,
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator, size: usize) !Random {
        return .{
            .allocator = allocator,
            .seeds = try allocator.alloc(usize, size),
        };
    }
    pub fn deinit(self: *Random) void {
        self.allocator.free(self.seeds);
    }
    pub fn random(self: *Random) usize {
        var x: usize = 0;
        var i: usize = 0;
        if (self.size == 0) {
            // for (i = 0; i < (int)seeds.size(); i++) {
            for (self.seeds) |_i| {
                self.seeds[i] = _i;
            }
            self.size = self.seeds.len;
        }

        i = rand() % self.size;
        x = self.seeds[i];
        self.size -= 1;
        self.seeds[i] = self.seeds[self.size];
        return x;
    }
};
// 网络延迟模拟器
const LatencySimulator = struct {
    current: u32 = 0,
    lostrate: usize = 0,
    rttmin: usize = 0,
    rttmax: usize = 0,
    nmax: usize = 0,
    p12: DelayTunnel,
    p21: DelayTunnel,
    r12: Random,
    r21: Random,
    tx1: usize = 0,
    tx2: usize = 0,
    allocator: std.mem.Allocator,
    const DelayTunnel = struct {
        list: std.ArrayList(DelayPacket),
        allocator: std.mem.Allocator,
        pub fn init(allocator: std.mem.Allocator) !DelayTunnel {
            return .{
                .allocator = allocator,
                .list = std.ArrayList(DelayPacket).init(allocator),
            };
        }
        pub fn deinit(self: *DelayTunnel) void {
            for (self.list.items) |*item| {
                item.deinit();
            }
            self.list.deinit();
        }
        pub fn push_back(self: *DelayTunnel, pkt: DelayPacket) !void {
            try self.list.append(pkt);
        }
        pub fn size(self: *DelayTunnel) usize {
            return self.list.items.len;
        }
        pub fn begin(self: *DelayTunnel) DelayPacket {
            return self.list.items[0];
        }
        pub fn removeBegin(self: *DelayTunnel) void {
            _ = self.list.swapRemove(0);
        }
    };
    pub fn init(allocator: std.mem.Allocator, lostrate: usize, rttmin: usize, rttmax: usize, nmax: usize) !LatencySimulator {
        var p12 = try DelayTunnel.init(allocator);
        errdefer p12.deinit();
        var p21 = try DelayTunnel.init(allocator);
        errdefer p21.deinit();
        var r12 = try Random.init(allocator, 100);
        errdefer r12.deinit();
        var r21 = try Random.init(allocator, 100);
        errdefer r21.deinit();
        return .{
            .current = @intCast(iclock()),
            .lostrate = lostrate / 2,
            .rttmin = rttmin / 2,
            .rttmax = rttmax / 2,
            .nmax = nmax,
            .allocator = allocator,
            .p12 = p12,
            .p21 = p21,
            .r12 = r12,
            .r21 = r21,
        };
    }
    pub fn deinit(self: *LatencySimulator) void {
        self.p12.deinit();
        self.p21.deinit();
        self.r12.deinit();
        self.r21.deinit();
    }
    // 发送数据
    // peer - 端点0/1，从0发送，从1接收；从1发送从0接收
    pub fn send(self: *LatencySimulator, peer: usize, data: []const u8) !void {
        if (peer == 0) {
            // tx1++;
            self.tx1 += 1;
            if (self.r12.random() < self.lostrate) return;
            if (self.p12.size() >= self.nmax) return;
        } else {
            // tx2++;
            self.tx2 += 1;
            if (self.r21.random() < self.lostrate) return;
            if (self.p21.size() >= self.nmax) return;
        }
        var pkt = try DelayPacket.init(self.allocator, data);
        errdefer pkt.deinit();
        const current = iclock();
        var delay = self.rttmin;
        if (self.rttmax > self.rttmin) delay += rand() % (self.rttmax - self.rttmin);
        pkt.setTs(@intCast(current + delay));
        if (peer == 0) {
            try self.p12.push_back(pkt);
        } else {
            try self.p21.push_back(pkt);
        }
    }
    // 接收数据
    fn recv(self: *LatencySimulator, peer: usize, data: []u8, _maxsize: usize) !usize {
        var maxsize = _maxsize;
        var pkt: DelayPacket = undefined;
        if (peer == 0) {
            if (self.p21.size() == 0) return error.LatencySimulator_p21_empty;
            pkt = self.p21.begin();
        } else {
            if (self.p12.size() == 0) return error.LatencySimulator_p12_empty;
            pkt = self.p12.begin();
        }

        const current = iclock();
        if (current < pkt.ts()) {
            return error.LatencySimulator_pkt_ts_not_right;
        }
        if (maxsize < pkt.size()) {
            return error.LatencySimulator_maxsize_lt_pkt_size;
        }
        if (peer == 0) {
            self.p21.removeBegin();
        } else {
            self.p12.removeBegin();
        }
        maxsize = pkt.size();
        std.mem.copyForwards(u8, data, pkt.ptr());
        pkt.deinit();
        return maxsize;
    }
};

// var random = std.rand.DefaultCsprng.init(std.mem.zeroes([32]u8));
var random = std.rand.DefaultPrng.init(0);
fn rand() u64 {
    // return std.rand.int(std.Random, u64);
    // return random.random().int(u64);
    // return 0;
    return random.next();
}
test "zkcp test" {
    std.testing.log_level = .debug;
    try Test(1);
}
var vnet: LatencySimulator = undefined;

pub fn Test(mode: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        std.log.debug("gpa check:{}", .{check});
    }
    const allocator = gpa.allocator();

    const MAX_TEST_PKT = 1000;
    vnet = try LatencySimulator.init(allocator, 10, 60, 125, 1000);
    defer vnet.deinit();

    // 创建两个端点的 kcp对象，第一个参数 conv是会话编号，同一个会话需要相同
    // 最后一个是 user参数，用来传递标识
    var kcp1 = try Kcp.init(allocator, 0x11223344, 0);
    std.log.debug("conv:{}", .{kcp1.conv});
    defer kcp1.deinit();
    var kcp2 = try Kcp.init(allocator, 0x11223344, 1);
    defer kcp2.deinit();

    // 设置kcp的下层输出，这里为 udp_output，模拟udp网络输出函数
    kcp1.setOutput(udp_output);
    kcp2.setOutput(udp_output);

    kcp1.logmask = zkcp.IKCP_LOG_OUT_OUTPUT | zkcp.IKCP_LOG_OUT_INPUT;
    // kcp1.writelogFunc = test_log;
    kcp2.logmask = zkcp.IKCP_LOG_OUT_OUTPUT | zkcp.IKCP_LOG_OUT_INPUT;
    // kcp2.writelogFunc = test_log;

    var current = iclock();
    var slap = current + 20;
    var index: u32 = 0;
    var next: u32 = 0;
    var sumrtt: i64 = 0;
    var count: usize = 0;
    var maxrtt: usize = 0;

    // 配置窗口大小：平均延迟200ms，每20ms发送一个包，
    // 而考虑到丢包重发，设置最大收发窗口为128
    // ikcp_wndsize(kcp1, 128, 128);
    _ = kcp1.wndSize(128, 128);
    _ = kcp2.wndSize(128, 128);

    // 判断测试用例的模式
    if (mode == 0) {
        // 默认模式
        _ = kcp1.noDelay(0, 10, 0, 0);
        _ = kcp2.noDelay(0, 10, 0, 0);
    } else if (mode == 1) {
        // 普通模式，关闭流控等
        _ = kcp1.noDelay(0, 10, 0, 1);
        _ = kcp2.noDelay(0, 10, 0, 1);
    } else {
        // 启动快速模式
        // 第二个参数 nodelay-启用以后若干常规加速将启动
        // 第三个参数 interval为内部处理时钟，默认设置为 10ms
        // 第四个参数 resend为快速重传指标，设置为2
        // 第五个参数 为是否禁用常规流控，这里禁止
        _ = kcp1.noDelay(2, 10, 2, 1);
        _ = kcp2.noDelay(2, 10, 2, 1);

        kcp1.rx_minrto = 10;
        kcp1.fastresend = 1;
    }

    var buffer = std.mem.zeroes([2000]u8);
    var hr: usize = 0;

    var ts1: u32 = @intCast(iclock());

    while (true) {
        isleep(1);
        current = iclock();
        try kcp1.update(iclock());

        try kcp2.update(iclock());

        // 每隔 20ms，kcp1发送数据
        while (current >= slap) : (slap += 20) {
            std.mem.writeInt(u32, buffer[0..4], index, native_endian);
            index += 1;
            std.mem.writeInt(u32, buffer[4..8], current, native_endian);

            // 发送上层协议包
            _ = try kcp1.send(buffer[0..8]);
        }

        // 处理虚拟网络：检测是否有udp包从p1->p2
        while (true) {
            hr = vnet.recv(1, &buffer, 2000) catch {
                break;
            };
            if (hr <= 0) break;
            // 如果 p2收到udp，则作为下层协议输入到kcp2

            _ = try kcp2.input(buffer[0..hr]);
        }

        // 处理虚拟网络：检测是否有udp包从p2->p1
        while (true) {
            hr = vnet.recv(0, &buffer, 2000) catch {
                break;
            };
            if (hr <= 0) break;
            // 如果 p1收到udp，则作为下层协议输入到kcp1
            _ = try kcp1.input(buffer[0..hr]);
        }

        // kcp2接收到任何包都返回回去
        while (true) {
            hr = kcp2.recv(buffer[0..10], false) catch {
                break;
            };
            // 没有收到包就退出
            if (hr <= 0) break;
            // 如果收到包就回射
            _ = try kcp2.send(buffer[0..hr]);
        }

        // kcp1收到kcp2的回射数据
        while (true) {
            hr = kcp1.recv(buffer[0..10], false) catch {
                break;
            };
            // 没有收到包就退出
            if (hr <= 0) break;
            const sn: u32 = std.mem.readInt(u32, buffer[0..4], native_endian);
            const ts: u32 = std.mem.readInt(u32, buffer[4..8], native_endian);
            const rtt = current - ts;

            if (sn != next) {
                // 如果收到的包不连续
                std.log.debug("ERROR sn {d}<->{d}\n", .{ count, next });
                return;
            }

            next += 1;
            sumrtt += rtt;
            count += 1;
            if (rtt > maxrtt) maxrtt = rtt;

            std.log.debug("[RECV] mode={d} sn={d} rtt={d}", .{ mode, sn, rtt });
        }
        if (next > MAX_TEST_PKT) break;
    }

    ts1 = iclock() - ts1;

    const names: [3][]const u8 = .{ "default", "normal", "fast" };
    std.log.debug("{s} mode result ({d}ms):\n", .{ names[mode], ts1 });
    std.log.debug("avgrtt={d} maxrtt={d} tx={d}\n", .{ @as(u64, @bitCast(sumrtt)) / count, maxrtt, vnet.tx1 });
    std.log.debug("press enter to next ...\n", .{});
    _ = try std.io.getStdIn().read(buffer[0..1]);
}
// 模拟网络：模拟发送一个 udp包
fn udp_output(buf: []const u8, kcp: *Kcp, user: ?usize) usize {
    _ = kcp;
    if (user) |_user| {
        vnet.send(_user, buf) catch {};
    } else {
        unreachable;
    }
    return 0;
}

fn test_log(log: []const u8, kcp: *Kcp, user: ?usize) void {
    _ = kcp;
    _ = user;
    std.log.debug("{s}", .{log});
}
