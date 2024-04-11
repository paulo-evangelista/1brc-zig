// 
// 
// 
// 
// 
//      @: Representa as funções especificas do compilador
// 

const std = @import("std");
const builtin = @import("builtin");

// Define a qu
const MAP_CAPACITY = 512 * 2 * 2;

// Um alias para o tipo "signed int 32bits"
const T = i32;
// Um alias para o tipo "float 32bits"
const F = f32;

// O tipo Stat define uma estátistica, ou seja, os dados de um local.
//      ou melhor ainda, uma linha do arquivo do 1BRC.

// Struct que vai salvar estatísticas.
// Quando encontrarmos novas estátisticas para um local já salvo, vamos mesclar as estatísticas.
const Stat = struct {
    // Vai salvar o menor valor encontrado
    min: F,
    // Vai salvar o maior valor encontrado
    max: F,
    // Vai a soma de todos os valores encontrados
    sum: F,
    // Vai salvar a quantidade de valores encontrados
    count: u32,

    // Faz o merge entre duas estatísticas
    pub fn mergeIn(self: *Stat, other: Stat) void {
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
        self.sum += other.sum;
        self.count += other.count;
    }

    // Adiciona um novo dado (float) à estatística
    pub fn addItem(self: *Stat, item: F) void {
        self.min = @min(self.min, item);
        self.max = @max(self.max, item);
        self.sum += item;
        self.count += 1;
    }
};

// Define uma estrutura de Contexto que será usado por cada worker
const WorkerCtx = struct {

    // Aqui criamos um Hashmap que vai apontar o nome de um local para uma Stat
    map: std.StringHashMap(Stat),
    // E aqui um array de bytes que vai salvar o nome dos locais pelos quais esse contexto passou
    countries: std.ArrayList([]const u8),

    // Inicializa o WorkerCtx, e recebe um locador de memória
    // A ! no retorno da função indica que ela pode falhar e retornar um erro
    pub fn init(allocator: std.mem.Allocator) !WorkerCtx {
        var self: WorkerCtx = undefined;
        self.map = std.StringHashMap(Stat).init(allocator);
        try self.map.ensureTotalCapacity(MAP_CAPACITY);
        self.countries = std.ArrayList([]const u8).init(allocator);
        return self;
    }
    pub fn deinit(self: *WorkerCtx) void {
        self.map.deinit();
        self.countries.deinit();
    }
};

inline fn parseSimpleFloat(chunk: []const u8, pos: *usize) F {
    var inum: i32 = 0;
    var is_neg: bool = false;
    for (0..6) |i| {
        const idx = pos.* + i;
        const item = chunk[idx];
        switch (item) {
            '-' => is_neg = true,
            '0'...'9' => {
                inum *= 10;
                inum += item - '0';
            },
            '\n' => {
                pos.* = idx + 1;
                break;
            },
            else => {},
        }
    }
    inum *= if (is_neg) -1 else 1;
    const num: f32 = @as(f32, @floatFromInt(inum)) / 10;
    return num;
}

fn threadRun(
    chunk: []const u8,
    chunk_idx: usize,
    main_ctx: *WorkerCtx,
    main_mutex: *std.Thread.Mutex,
    wg: *std.Thread.WaitGroup,
) void {
    defer wg.finish();
    var ctx = WorkerCtx.init(std.heap.c_allocator) catch unreachable;
    defer ctx.deinit();
    std.log.debug("Running thread {}!", .{chunk_idx});
    var pos: usize = 0;
    while (pos < chunk.len) {
        const new_pos = std.mem.indexOfScalarPos(u8, chunk, pos, ';') orelse chunk.len;
        const city = chunk[pos..new_pos];
        pos = new_pos + 1;
        // the rest of the line is a (optional negative) float with 1-2 digits then 1 decimal place.
        // -23.1, 1.2, -8.5
        const num = parseSimpleFloat(chunk, &pos);
        const entry = ctx.map.getOrPut(city) catch unreachable;
        if (entry.found_existing) {
            entry.value_ptr.addItem(num);
        } else {
            entry.value_ptr.* = Stat{ .min = num, .max = num, .sum = num, .count = 1 };
        }
    }

    var it = ctx.map.iterator();
    while (it.next()) |entry| {
        const country = entry.key_ptr.*;
        const stat = entry.value_ptr.*;
        main_mutex.lock();
        if (main_ctx.map.getPtr(country)) |main_stat| {
            main_stat.mergeIn(stat);
        } else {
            main_ctx.countries.append(country) catch unreachable;
            main_ctx.map.put(country, stat) catch unreachable;
        }
        main_mutex.unlock();
    }
    std.log.debug("Finished thread {}!", .{chunk_idx});
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == std.math.Order.lt;
}

pub fn main() !void {
    std.log.debug("Starting!", .{});
    var args = try std.process.argsWithAllocator(std.heap.c_allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name
    const file_name = args.next() orelse "measurements.txt";
    const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
    defer file.close();
    //
    const file_len: usize = std.math.cast(usize, try file.getEndPos()) orelse std.math.maxInt(usize);
    const mapped_mem = try std.os.mmap(
        null,
        file_len,
        std.os.PROT.READ,
        std.os.MAP.PRIVATE,
        file.handle,
        0,
    );
    defer std.os.munmap(mapped_mem);
    if (builtin.os.tag == .linux) try std.os.madvise(mapped_mem.ptr, file_len, std.os.MADV.HUGEPAGE);

    var tp: std.Thread.Pool = undefined;
    try tp.init(.{ .allocator = std.heap.c_allocator });
    var wg = std.Thread.WaitGroup{};

    var main_ctx = try WorkerCtx.init(std.heap.c_allocator);
    defer main_ctx.deinit();
    var main_mutex = std.Thread.Mutex{};

    var chunk_start: usize = 0;
    const job_count = try std.Thread.getCpuCount() - 1;
    for (0..job_count) |i| {
        const search_start = mapped_mem.len / job_count * (i + 1);
        const chunk_end = std.mem.indexOfScalarPos(u8, mapped_mem, search_start, '\n') orelse mapped_mem.len;
        const chunk: []const u8 = mapped_mem[chunk_start..chunk_end];
        chunk_start = chunk_end + 1;
        wg.start();
        try tp.spawn(threadRun, .{ chunk, i, &main_ctx, &main_mutex, &wg });
        if (chunk_start >= mapped_mem.len) break;
    }
    std.log.debug("Waiting and working", .{});
    tp.waitAndWork(&wg);
    std.log.debug("Finished waiting and working", .{});

    std.mem.sortUnstable([]const u8, main_ctx.countries.items, {}, strLessThan);
    std.debug.print("{{", .{});
    for (main_ctx.countries.items, 0..) |country, i| {
        const stat = main_ctx.map.get(country).?;
        const avg = stat.sum / @as(F, @floatFromInt(stat.count));
        std.debug.print("{s}={d:.1}/{d:.1}/{d:.1}", .{ country, stat.min, avg, stat.max });
        if (i + 1 != main_ctx.countries.items.len) std.debug.print(", ", .{});
    }
    std.debug.print("}}\n", .{});
}

test "parseSimpleFloat - pos 3 digs" {
    var pos: usize = 0;
    const str = "12.1\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, 12.1), num);
    try std.testing.expectEqual(str.len, pos);
}

test "parseSimpleFloat - neg 3 digs" {
    var pos: usize = 0;
    const str = "-25.8\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, -25.8), num);
    try std.testing.expectEqual(str.len, pos);
}

test "parseSimpleFloat - pos 2 digs" {
    var pos: usize = 0;
    const str = "1.9\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, 1.9), num);
    try std.testing.expectEqual(str.len, pos);
}

test "parseSimpleFloat - neg 2 digs" {
    var pos: usize = 0;
    const str = "-1.9\n";
    const num = parseSimpleFloat(str, &pos);
    try std.testing.expectEqual(@as(F, -1.9), num);
    try std.testing.expectEqual(str.len, pos);
}
