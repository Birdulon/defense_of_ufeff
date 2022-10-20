const ImmRenderer = @This();

const gl = @import("gl33.zig");
const zm = @import("zmath");
const shader = @import("shader.zig");
const texture = @import("texture.zig");
const Rect = @import("Rect.zig");

const vssrc = @embedFile("ImmRenderer.vert");
const fssrc = @embedFile("ImmRenderer.frag");

const Vertex = extern struct {
    xyuv: zm.F32x4,
    rgba: zm.F32x4,
};

const Uniforms = struct {
    uTransform: gl.GLint,
};

prog: shader.Program,
vao: gl.GLuint,
buffer: gl.GLuint,
transform: zm.Mat,
uniforms: Uniforms,

pub fn create() ImmRenderer {
    var self: ImmRenderer = undefined;
    self.prog = shader.createProgramFromSource(vssrc, fssrc);
    self.uniforms = shader.getUniformLocations(Uniforms, self.prog);
    gl.genVertexArrays(1, &self.vao);
    gl.genBuffers(1, &self.buffer);
    gl.bindVertexArray(self.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, self.buffer);
    gl.vertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*anyopaque, @offsetOf(Vertex, "xyuv")));
    gl.vertexAttribPointer(1, 4, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*anyopaque, @offsetOf(Vertex, "rgba")));
    gl.enableVertexAttribArray(0);
    gl.enableVertexAttribArray(1);
    return self;
}

pub fn destroy(self: *ImmRenderer) void {
    gl.deleteBuffers(1, &self.buffer);
    gl.deleteVertexArrays(1, &self.vao);
}

pub fn setOutputDimensions(self: *ImmRenderer, w: u32, h: u32) void {
    const wf = @intToFloat(f32, w);
    const hf = @intToFloat(f32, h);
    self.transform = zm.orthographicOffCenterRh(0, wf, 0, hf, 0, 1);
}

pub fn begin(self: ImmRenderer) void {
    gl.useProgram(self.prog.handle);
    gl.bindVertexArray(self.vao);
    gl.uniformMatrix4fv(self.uniforms.uTransform, 1, gl.TRUE, zm.arrNPtr(&self.transform));
}

pub fn drawQuad(self: ImmRenderer, x: i32, y: i32, w: u32, h: u32, r: f32, g: f32, b: f32) void {
    const left = @intToFloat(f32, x);
    const right = @intToFloat(f32, x + @intCast(i32, w));
    const top = @intToFloat(f32, y);
    const bottom = @intToFloat(f32, y + @intCast(i32, h));
    const rgba = zm.f32x4(r, g, b, 1);

    const vertices = [4]Vertex{
        Vertex{ .xyuv = zm.f32x4(left, top, 0, 1), .rgba = rgba },
        Vertex{ .xyuv = zm.f32x4(left, bottom, 0, 0), .rgba = rgba },
        Vertex{ .xyuv = zm.f32x4(right, bottom, 1, 0), .rgba = rgba },
        Vertex{ .xyuv = zm.f32x4(right, top, 1, 1), .rgba = rgba },
    };

    gl.bindBuffer(gl.ARRAY_BUFFER, self.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, 4 * @sizeOf(Vertex), &vertices, gl.STREAM_DRAW);
    gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);
}

pub fn drawQuadTextured(self: ImmRenderer, t: texture.TextureState, src: Rect, dest: Rect) void {
    const uv_left = @intToFloat(f32, src.x) / @intToFloat(f32, t.width);
    const uv_right = @intToFloat(f32, src.right()) / @intToFloat(f32, t.width);
    const uv_top = 1 - @intToFloat(f32, src.y) / @intToFloat(f32, t.height);
    const uv_bottom = 1 - @intToFloat(f32, src.bottom()) / @intToFloat(f32, t.height);

    const left = @intToFloat(f32, dest.x);
    const right = @intToFloat(f32, dest.right());
    const top = @intToFloat(f32, dest.y);
    const bottom = @intToFloat(f32, dest.bottom());
    const rgba = zm.f32x4(1, 1, 1, 1);

    const vertices = [4]Vertex{
        Vertex{ .xyuv = zm.f32x4(left, top, uv_left, uv_top), .rgba = rgba },
        Vertex{ .xyuv = zm.f32x4(left, bottom, uv_left, uv_bottom), .rgba = rgba },
        Vertex{ .xyuv = zm.f32x4(right, bottom, uv_right, uv_bottom), .rgba = rgba },
        Vertex{ .xyuv = zm.f32x4(right, top, uv_right, uv_top), .rgba = rgba },
    };

    gl.bindBuffer(gl.ARRAY_BUFFER, self.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, 4 * @sizeOf(Vertex), &vertices, gl.STREAM_DRAW);
    gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);
}
