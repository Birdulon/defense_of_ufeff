const MenuState = @This();

const std = @import("std");
const Game = @import("Game.zig");
const gl = @import("gl33");
const tilemap = @import("tilemap.zig");
const Rect = @import("Rect.zig");
const Rectf = @import("Rectf.zig");
const Camera = @import("Camera.zig");
const SpriteBatch = @import("SpriteBatch.zig");
const WaterRenderer = @import("WaterRenderer.zig");
const zm = @import("zmath");
const anim = @import("animation.zig");
const wo = @import("world.zig");
const bmfont = @import("bmfont.zig");
const QuadBatch = @import("QuadBatch.zig");
const BitmapFont = bmfont.BitmapFont;
const particle = @import("particle.zig");
const audio = @import("audio.zig");
// eventually should probably eliminate this dependency
const sdl = @import("sdl.zig");
const ui = @import("ui.zig");
const Texture = @import("texture.zig").Texture;

game: *Game,
r_batch: SpriteBatch,
r_font: BitmapFont,
fontspec: bmfont.BitmapFontSpec,
ui_root: ui.Root,
ui_tip: *ui.Button,
btn_newgame: *ui.Button,
rng: std.rand.DefaultPrng,
tip_index: usize = 0,

const tips = [_][]const u8{
    "You can build over top of walls!\nThis lets you maze first, then build towers.",
};

pub fn create(game: *Game) !*MenuState {
    var self = try game.allocator.create(MenuState);
    self.* = .{
        .game = game,
        .r_batch = SpriteBatch.create(),
        .r_font = undefined,
        .fontspec = undefined,
        .ui_root = ui.Root.init(game.allocator),
        .rng = std.rand.DefaultPrng.init(@intCast(u64, std.time.milliTimestamp())),
        // Initialized below
        .ui_tip = undefined,
        .btn_newgame = undefined,
    };
    self.r_font = BitmapFont.init(&self.r_batch);

    self.btn_newgame = try self.ui_root.createButton();
    self.btn_newgame.text = "New Game";
    self.btn_newgame.rect = Rect.init(0, 0, 128, 32);
    self.btn_newgame.rect.centerOn(Game.INTERNAL_WIDTH / 2, 100);
    self.btn_newgame.texture = self.game.texman.getNamedTexture("ui_iconframe.png");
    self.btn_newgame.setCallback(self, onNewGameClick);
    try self.ui_root.addChild(self.btn_newgame.control());

    self.ui_tip = try self.ui_root.createButton();
    self.ui_tip.texture = self.game.texman.getNamedTexture("special.png");
    self.ui_tip.texture_rects = [4]Rect{
        // .normal
        Rect.init(208, 48, 16, 16),
        // .hover
        Rect.init(208, 48, 16, 16),
        // .down
        Rect.init(208, 48, 16, 16),
        // .disabled
        Rect.init(208, 48, 16, 16),
    };
    self.ui_tip.rect = Rect.init(0, 0, 16, 16);
    self.ui_tip.callback = onButtonClick;
    self.ui_tip.userdata = self;
    self.ui_tip.rect.alignRight(Game.INTERNAL_WIDTH);
    self.ui_tip.rect.alignBottom(Game.INTERNAL_HEIGHT);
    self.ui_tip.rect.translate(-8, -8);
    try self.ui_root.addChild(self.ui_tip.control());

    // TODO probably want a better way to manage this, direct IO shouldn't be here
    // TODO undefined minefield, need to be more careful. Can't deinit an undefined thing.
    self.fontspec = try loadFontSpec(self.game.allocator, "assets/tables/CommonCase.json");
    return self;
}

fn showRandomTip(self: *MenuState) void {
    self.tip_index = self.rng.random().intRangeLessThan(usize, 0, tips.len);
}

fn onNewGameClick(button: *ui.Button, self: *MenuState) void {
    _ = button;
    self.game.audio.playSound("assets/sounds/click.ogg").release();
    self.game.changeState(.play);
}

fn onButtonClick(button: *ui.Button, userdata: ?*anyopaque) void {
    _ = button;
    var data = @ptrCast(*MenuState, @alignCast(@alignOf(MenuState), userdata));
    data.game.audio.playSound("assets/sounds/click.ogg").release();
    data.showRandomTip();
}

fn loadFontSpec(allocator: std.mem.Allocator, filename: []const u8) !bmfont.BitmapFontSpec {
    var font_file = try std.fs.cwd().openFile(filename, .{});
    defer font_file.close();
    var spec_json = try font_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(spec_json);
    return try bmfont.BitmapFontSpec.initJson(allocator, spec_json);
}

pub fn destroy(self: *MenuState) void {
    self.fontspec.deinit();
    self.r_batch.destroy();
    self.ui_root.deinit();
    self.game.allocator.destroy(self);
}

pub fn enter(self: *MenuState, from: ?Game.StateId) void {
    _ = self;
    _ = from;
}

pub fn leave(self: *MenuState, to: ?Game.StateId) void {
    _ = self;
    _ = to;
}

pub fn update(self: *MenuState) void {
    _ = self;
}

pub fn render(self: *MenuState, alpha: f64) void {
    _ = alpha;

    gl.clearColor(0x64.0 / 255.0, 0x95.0 / 255.0, 0xED.0 / 255.0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);

    self.r_font.begin(.{
        .texture = self.game.texman.getNamedTexture("CommonCase.png"),
        .spec = &self.fontspec,
    });

    var measured = self.r_font.measureText(tips[self.tip_index]);
    measured.centerOn(Game.INTERNAL_WIDTH / 2, @floatToInt(i32, 0.8 * Game.INTERNAL_HEIGHT));

    self.r_font.drawText(tips[self.tip_index], .{ .dest = Rect.init(0, 200, 512, 50), .h_alignment = .center });
    self.r_font.end();

    self.r_batch.setOutputDimensions(Game.INTERNAL_WIDTH, Game.INTERNAL_HEIGHT);
    ui.renderUI(.{
        .r_batch = &self.r_batch,
        .r_font = &self.r_font,
        .r_imm = &self.game.imm,
        .font_texture = self.game.texman.getNamedTexture("CommonCase.png"),
        .font_spec = &self.fontspec,
    }, self.ui_root);
}

pub fn handleEvent(self: *MenuState, ev: sdl.SDL_Event) void {
    if (ev.type == .SDL_KEYDOWN) {
        switch (ev.key.keysym.sym) {
            sdl.SDLK_ESCAPE => std.process.exit(0),
            else => {},
        }
    }

    if (ev.type == .SDL_MOUSEMOTION) {
        const mouse_p = self.game.unproject(
            self.game.input.mouse.client_x,
            self.game.input.mouse.client_y,
        );
        const ui_args = ui.MouseEventArgs{
            .x = mouse_p[0],
            .y = mouse_p[1],
            .buttons = ui.SDLBackend.mouseEventToButtons(ev),
        };
        self.ui_root.handleMouseMove(ui_args);
    }

    if (ev.type == .SDL_MOUSEBUTTONDOWN) {
        const mouse_p = self.game.unproject(
            self.game.input.mouse.client_x,
            self.game.input.mouse.client_y,
        );
        const ui_args = ui.MouseEventArgs{
            .x = mouse_p[0],
            .y = mouse_p[1],
            .buttons = ui.SDLBackend.mouseEventToButtons(ev),
        };
        _ = self.ui_root.handleMouseDown(ui_args);
    }

    if (ev.type == .SDL_MOUSEBUTTONUP) {
        const mouse_p = self.game.unproject(
            self.game.input.mouse.client_x,
            self.game.input.mouse.client_y,
        );
        const ui_args = ui.MouseEventArgs{
            .x = mouse_p[0],
            .y = mouse_p[1],
            .buttons = ui.SDLBackend.mouseEventToButtons(ev),
        };
        _ = self.ui_root.handleMouseUp(ui_args);
    }
}
