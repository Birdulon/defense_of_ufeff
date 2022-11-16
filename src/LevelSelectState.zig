const LevelSelectState = @This();

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
const World = wo.World;
const bmfont = @import("bmfont.zig");
const QuadBatch = @import("QuadBatch.zig");
const BitmapFont = bmfont.BitmapFont;
const particle = @import("particle.zig");
const audio = @import("audio.zig");
// eventually should probably eliminate this dependency
const sdl = @import("sdl.zig");
const ui = @import("ui.zig");
const Texture = @import("texture.zig").Texture;
const WorldRenderer = @import("WorldRenderer.zig");
const FingerRenderer = @import("FingerRenderer.zig");
const FrameTimer = @import("timing.zig").FrameTimer;

const ProgressionState = extern struct {
    maps: [256]bool = .{false} ** 256,
    num_complete: u32 = 0,
    last_map_entered: u32 = 0,

    fn setMapComplete(self: *ProgressionState, mapid: u32) void {
        self.maps[mapid] = true;
        self.num_complete = @intCast(u32, std.mem.count(bool, &self.maps, &[_]bool{true}));
    }
};

const MapButtonState = struct {
    state: *LevelSelectState,
    /// Index into ProgressionState.maps
    mapid: u32,
    mapname: []const u8,
};

const Substate = enum {
    none,
    fadein,
    fadeout,
};

const Finger = struct {
    start_x: f32 = 0,
    start_y: f32 = 0,
    world_x: f32 = 0,
    world_y: f32 = 0,
    p_world_x: f32 = 0,
    p_world_y: f32 = 0,
    target_x: f32 = 0,
    target_y: f32 = 0,
    move_timer: FrameTimer = .{},

    fn update(self: *Finger, frame: u64) void {
        self.p_world_x = self.world_x;
        self.p_world_y = self.world_y;
        const t = self.move_timer.progressClamped(frame);
        const k = std.math.pow(f32, t, 5);
        self.world_x = zm.lerpV(self.start_x, self.target_x, k);
        self.world_y = zm.lerpV(self.start_y, self.target_y, k);
    }

    fn moveTo(self: *Finger, target_x: f32, target_y: f32, timer: FrameTimer) void {
        self.move_timer = timer;
        self.start_x = self.world_x;
        self.start_y = self.world_y;
        self.target_x = target_x;
        self.target_y = target_y;
    }

    fn getInterpWorldPosition(self: *Finger, alpha: f32) [2]f32 {
        return [2]f32{
            zm.lerpV(self.p_world_x, self.world_x, alpha),
            zm.lerpV(self.p_world_y, self.world_y, alpha),
        };
    }
};

game: *Game,
fontspec: bmfont.BitmapFontSpec,
ui_root: ui.Root,
music_params: ?*audio.AudioParameters = null,
r_world: *WorldRenderer,
r_finger: FingerRenderer,
finger: Finger = .{},
world: World,
prog_state: ProgressionState = .{},
arena: std.heap.ArenaAllocator,
sub: Substate = .none,
fade_timer: FrameTimer = .{},
buttons: []*ui.Button,
button_states: []MapButtonState,
num_buttons: usize = 0,

const camera = Camera{
    .view = Rect.init(0, 0, Game.INTERNAL_WIDTH, Game.INTERNAL_HEIGHT),
};

pub fn create(game: *Game) !*LevelSelectState {
    var self = try game.allocator.create(LevelSelectState);
    self.* = .{
        .game = game,
        .fontspec = undefined,
        .ui_root = ui.Root.init(game.allocator, &game.sdl_backend),
        .arena = std.heap.ArenaAllocator.init(game.allocator),
        .r_finger = FingerRenderer.create(),
        // Initialized below
        .r_world = undefined,
        .world = undefined,
        .buttons = undefined,
        .button_states = undefined,
    };

    errdefer self.r_finger.destroy();
    errdefer self.ui_root.deinit();

    self.r_world = try WorldRenderer.create(game.allocator, &game.renderers);
    errdefer self.r_world.destroy(game.allocator);

    self.world = try wo.loadWorldFromJson(game.allocator, "assets/maps/level_select.tmj");
    errdefer self.world.deinit();

    self.buttons = try game.allocator.alloc(*ui.Button, self.prog_state.maps.len);
    errdefer game.allocator.free(self.buttons);

    self.button_states = try game.allocator.alloc(MapButtonState, self.prog_state.maps.len);
    errdefer game.allocator.free(self.button_states);

    const m01 = self.world.getCustomRectByName("map01") orelse return error.NoMap01;
    const m02 = self.world.getCustomRectByName("map02") orelse return error.NoMap02;
    const m03 = self.world.getCustomRectByName("map03") orelse return error.NoMap03;
    try self.createButtonForRect(m01, 0);
    try self.createButtonForRect(m02, 1);
    try self.createButtonForRect(m03, 2);

    try self.loadProgression();
    self.updateButtonStates();
    self.moveFingerToRecommendedMap();

    // TODO probably want a better way to manage this, direct IO shouldn't be here
    // TODO undefined minefield, need to be more careful. Can't deinit an undefined thing.
    self.fontspec = try loadFontSpec(self.game.allocator, "assets/tables/CommonCase.json");
    errdefer self.fontspec.deinit();

    return self;
}

pub fn destroy(self: *LevelSelectState) void {
    self.game.allocator.free(self.buttons);
    self.game.allocator.free(self.button_states);
    self.r_finger.destroy();
    self.arena.deinit();
    if (self.music_params) |params| {
        params.release();
    }
    self.r_world.destroy(self.game.allocator);
    self.world.deinit();
    self.fontspec.deinit();
    self.ui_root.deinit();
    self.game.allocator.destroy(self);
}

fn createButtonForRect(self: *LevelSelectState, rect: Rect, mapid: u32) !void {
    var btn = try self.ui_root.createButton();
    var allocator = self.arena.allocator();
    const mapname = try std.fmt.allocPrint(allocator, "map{d:0>2}", .{mapid + 1});
    self.button_states[self.num_buttons] = .{
        .mapid = mapid,
        .mapname = mapname,
        .state = self,
    };
    btn.rect = Rect.init(0, 0, 32, 32);
    btn.rect.centerOn(rect.centerPoint()[0], rect.centerPoint()[1]);
    btn.texture_rects = [4]Rect{
        Rect.init(0, 0, 32, 32),
        Rect.init(0, 32, 32, 32),
        Rect.init(0, 64, 32, 32),
        Rect.init(0, 96, 32, 32),
    };
    btn.setTexture(self.game.texman.getNamedTexture("level_select_button.png"));
    btn.tooltip_text = try std.fmt.allocPrint(allocator, "Map {d}", .{mapid + 1});
    btn.state = .disabled;
    try self.ui_root.addChild(btn.control());
    btn.ev_click.setCallback(&self.button_states[self.num_buttons], onLevelButtonClick);
    self.buttons[self.num_buttons] = btn;
    self.num_buttons += 1;
}

fn updateButtonStates(self: *LevelSelectState) void {
    var i: usize = 0;
    while (i <= self.prog_state.num_complete) : (i += 1) {
        self.buttons[i].state = .normal;
    }
}

fn onLevelButtonClick(button: *ui.Button, state: *MapButtonState) void {
    _ = button;
    state.state.prog_state.last_map_entered = state.mapid;
    state.state.game.st_play.loadWorld(state.mapname);
    state.state.beginFadeOut();
}

fn loadFontSpec(allocator: std.mem.Allocator, filename: []const u8) !bmfont.BitmapFontSpec {
    var font_file = try std.fs.cwd().openFile(filename, .{});
    defer font_file.close();
    var spec_json = try font_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(spec_json);
    return try bmfont.BitmapFontSpec.initJson(allocator, spec_json);
}

pub fn enter(self: *LevelSelectState, from: ?Game.StateId) void {
    if (self.music_params) |params| {
        params.paused.store(false, .SeqCst);
    } else {
        self.music_params = self.game.audio.playMusic("assets/music/Daybreak.ogg", .{});
    }
    self.beginFadeIn();

    if (from == Game.StateId.play) {
        if (self.game.st_play.world.player_won) {
            self.prog_state.setMapComplete(self.prog_state.last_map_entered);
            self.saveProgression() catch |err| {
                std.log.err("Failed to save progression: {!}", .{err});
            };
            self.updateButtonStates();
        }
    }
    self.moveFingerToRecommendedMap();
}

pub fn leave(self: *LevelSelectState, to: ?Game.StateId) void {
    _ = to;
    if (self.music_params) |params| {
        params.paused.store(true, .SeqCst);
    }
}

pub fn update(self: *LevelSelectState) void {
    if (self.music_params) |params| {
        const t = self.fade_timer.progressClamped(self.game.frame_counter);
        if (self.sub == .fadein or self.sub == .none) {
            params.volume.store(t, .SeqCst);
        } else if (self.sub == .fadeout) {
            params.volume.store(1 - t, .SeqCst);
        }
    }
    if (self.sub == .fadein and self.fade_timer.expired(self.game.frame_counter)) {
        self.sub = .none;
    } else if (self.sub == .fadeout and self.fade_timer.expired(self.game.frame_counter)) {
        self.endFadeOut();
    }

    self.r_world.updateAnimations();
    self.finger.update(self.game.frame_counter);
}

pub fn render(self: *LevelSelectState, alpha: f64) void {
    self.game.renderers.r_batch.setOutputDimensions(Game.INTERNAL_WIDTH, Game.INTERNAL_HEIGHT);

    self.r_world.renderTilemap(camera, &self.world.map, self.game.frame_counter);

    ui.renderUI(.{
        .r_batch = &self.game.renderers.r_batch,
        .r_font = &self.game.renderers.r_font,
        .r_imm = &self.game.renderers.r_imm,
        .font_texture = self.game.texman.getNamedTexture("CommonCase.png"),
        .font_spec = &self.fontspec,
    }, self.ui_root);

    self.r_finger.setOutputDimensions(Game.INTERNAL_WIDTH, Game.INTERNAL_HEIGHT);
    self.r_finger.beginTextured(.{
        .texture = self.game.texman.getNamedTexture("finger.png"),
    });
    const p = self.finger.getInterpWorldPosition(@floatCast(f32, alpha));
    self.r_finger.drawFinger(p[0], p[1], @intToFloat(f32, self.game.frame_counter) / 8.0);

    self.renderFade();
}

pub fn handleEvent(self: *LevelSelectState, ev: sdl.SDL_Event) void {
    if (self.sub != .none) {
        return;
    }
    _ = self.ui_root.backend.dispatchEvent(ev, &self.ui_root);
}

fn beginFadeIn(self: *LevelSelectState) void {
    self.sub = .fadein;
    self.fade_timer = FrameTimer.initSeconds(self.game.frame_counter, 2);
}

fn beginFadeOut(self: *LevelSelectState) void {
    self.sub = .fadeout;
    self.fade_timer = FrameTimer.initSeconds(self.game.frame_counter, 2);
}

fn endFadeOut(self: *LevelSelectState) void {
    std.debug.assert(self.sub == .fadeout);
    self.sub = .none;
    self.game.changeState(.play);
}

fn renderFade(self: *LevelSelectState) void {
    if (self.sub != .fadein and self.sub != .fadeout) {
        return;
    }

    const t_out = self.fade_timer.progressClamped(self.game.frame_counter);
    const t_in = 1 - t_out;
    const a = if (self.sub == .fadein) t_in else t_out;

    self.game.renderers.r_imm.beginUntextured();
    self.game.renderers.r_imm.drawQuadRGBA(Rect.init(0, 0, Game.INTERNAL_WIDTH, Game.INTERNAL_HEIGHT), zm.f32x4(0, 0, 0, a));
}

fn saveProgression(self: *LevelSelectState) !void {
    var f = try std.fs.cwd().createFile("progression.dat", .{});
    defer f.close();
    try f.writer().writeStruct(self.prog_state);
}

fn loadProgression(self: *LevelSelectState) !void {
    var f = std.fs.cwd().openFile("progression.dat", .{}) catch |err| {
        if (err == error.FileNotFound) {
            return;
        } else {
            return err;
        }
    };
    defer f.close();
    self.prog_state = try f.reader().readStruct(ProgressionState);
}

fn moveFingerToRecommendedMap(self: *LevelSelectState) void {
    if (self.prog_state.num_complete < self.num_buttons) {
        const b = self.buttons[self.prog_state.num_complete];
        const p = b.rect.centerPoint();
        self.finger.moveTo(
            @intToFloat(f32, p[0]),
            @intToFloat(f32, p[1]),
            FrameTimer.initSeconds(self.game.frame_counter, 3),
        );
    } else {
        self.finger.moveTo(
            Game.INTERNAL_WIDTH * 2,
            Game.INTERNAL_HEIGHT * -2,
            FrameTimer.initSeconds(self.game.frame_counter, 3),
        );
    }
}
