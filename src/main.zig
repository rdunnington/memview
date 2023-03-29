const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const wgpu = zgpu.wgpu;

const server = @import("server.zig");
const common = @import("common.zig");

const ServerContext = server.ServerContext;

// zig fmt: off
const wgsl_vs =
\\  @group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>,
\\      @location(0) color: vec3<f32>,
\\  }
\\  @stage(vertex) fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) color: vec3<f32>,
\\  ) -> VertexOut {
\\      var output: VertexOut;
\\      output.position_clip = vec4(position, 1.0) * object_to_clip;
\\      output.color = color;
\\      return output;
\\  }
;

const wgsl_fs =
\\  @stage(fragment) fn main(
\\      @location(0) color: vec3<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      return vec4(color, 1.0);
\\  }
// zig fmt: on
;

const DepthTexture = struct {
    texture: zgpu.TextureHandle,
    view: zgpu.TextureViewHandle,
};

fn createDepthTexture(gctx: *zgpu.GraphicsContext) DepthTexture {
    const texture = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const view = gctx.createTextureView(texture, .{});
    return DepthTexture{ .texture = texture, .view = view };
}

const Vertex = struct {
    position: [3]f32,
    color: [3]f32,
};

const GfxState = struct {
    gctx: *zgpu.GraphicsContext,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    vertex_buffer: zgpu.BufferHandle,
    index_buffer: zgpu.BufferHandle,
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    allocator: std.mem.Allocator,

    fn init(window: *zglfw.Window, allocator: std.mem.Allocator) !GfxState {
        const gctx = try zgpu.GraphicsContext.create(allocator, window);

        /////////////////////////////////////////////////////////////////////////
        // lifted from https://github.com/michal-z/zig-gamedev/blob/main/samples/triangle_wgpu/src/triangle_wgpu.zig
        // Create a bind group layout needed for our render pipeline.
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        });
        defer gctx.releaseResource(bind_group_layout);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline = pipline: {
            const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
            defer vs_module.release();

            const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
            defer fs_module.release();

            const color_targets = [_]wgpu.ColorTargetState{.{
                .format = zgpu.GraphicsContext.swapchain_format,
            }};

            const vertex_attributes = [_]wgpu.VertexAttribute{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = @offsetOf(Vertex, "color"), .shader_location = 1 },
            };
            const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(Vertex),
                .attribute_count = vertex_attributes.len,
                .attributes = &vertex_attributes,
            }};

            const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
                .vertex = wgpu.VertexState{
                    .module = vs_module,
                    .entry_point = "main",
                    .buffer_count = vertex_buffers.len,
                    .buffers = &vertex_buffers,
                },
                .primitive = wgpu.PrimitiveState{
                    .front_face = .ccw,
                    .cull_mode = .none,
                    .topology = .triangle_list,
                },
                .depth_stencil = &wgpu.DepthStencilState{
                    .format = .depth32_float,
                    .depth_write_enabled = true,
                    .depth_compare = .less,
                },
                .fragment = &wgpu.FragmentState{
                    .module = fs_module,
                    .entry_point = "main",
                    .target_count = color_targets.len,
                    .targets = &color_targets,
                },
            };
            break :pipline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
        };

        const bind_group = gctx.createBindGroup(bind_group_layout, &[_]zgpu.BindGroupEntryInfo{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(zm.Mat) },
        });

        // Create a vertex buffer.
        const color = [3]f32{ 0.0, 1.0, 0.0 };
        const vertex_data = [_]Vertex{
            .{ .position = [3]f32{ -0.5, -0.5, 0.0 }, .color = color },
            .{ .position = [3]f32{ 0.5, -0.5, 0.0 }, .color = color },
            .{ .position = [3]f32{ 0.5, 0.5, 0.0 }, .color = color },
            .{ .position = [3]f32{ -0.5, 0.5, 0.0 }, .color = color },

            // .{ .position = [3]f32{ 0.0, 0.5, 0.0 }, .color = [3]f32{ 1.0, 0.0, 0.0 } },
            // .{ .position = [3]f32{ -0.5, -0.5, 0.0 }, .color = [3]f32{ 0.0, 1.0, 0.0 } },
            // .{ .position = [3]f32{ 0.5, -0.5, 0.0 }, .color = [3]f32{ 0.0, 0.0, 1.0 } },
        };
        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = vertex_data.len * @sizeOf(Vertex),
        });
        gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, Vertex, vertex_data[0..]);

        // Create an index buffer.
        const index_data = [_]u32{ 0, 1, 2, 2, 3, 0 };
        const index_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = index_data.len * @sizeOf(u32),
        });
        gctx.queue.writeBuffer(gctx.lookupResource(index_buffer).?, 0, u32, index_data[0..]);

        // Create a depth texture and its 'view'.
        const depth = createDepthTexture(gctx);
        /////////////////////////////////////////////////////////////////////////

        return GfxState{
            .gctx = gctx,

            .pipeline = pipeline,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .depth_texture = depth.texture,
            .depth_texture_view = depth.view,

            .allocator = allocator,
        };
    }

    fn deinit(self: *GfxState) void {
        self.gctx.destroy(self.allocator);
    }
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    gfx: GfxState,
    server: ServerContext,
    all_messages: std.ArrayList(common.Message),
    new_messages: std.ArrayList(common.Message),
};

fn updateMessages(app: *AppContext) !void {
    try server.fetchMessages(&app.server, &app.new_messages);
    try app.all_messages.appendSlice(app.new_messages.items);
}

fn updateGui(app: *AppContext) void {
    var gctx: *zgpu.GraphicsContext = app.gfx.gctx;

    zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = @intToFloat(f32, gctx.swapchain_descriptor.width), .h = -1.0, .cond = .always });

    const title_bar_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
    };

    if (zgui.begin("menu_bar", .{ .flags = title_bar_flags })) {
        zgui.textUnformattedColored(.{ 0, 0.8, 0, 1 }, "Average :");
        zgui.sameLine(.{});
        zgui.text(
            "{d:.3} ms/frame ({d:.1} fps)",
            .{ gctx.stats.average_cpu_time, gctx.stats.fps },
        );
        zgui.end();
    }
}

fn draw(app: *AppContext) void {
    var gctx: *zgpu.GraphicsContext = app.gfx.gctx;

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;
    const t = @floatCast(f32, gctx.stats.time);

    const cam_world_to_view = zm.lookAtLh(
        zm.f32x4(0.0, 0.0, -3.0, 1.0),
        zm.f32x4(0.0, 0.0, 0.0, 1.0),
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );

    const cam_view_to_clip = zm.perspectiveFovLh(
        0.25 * std.math.pi,
        @intToFloat(f32, fb_width) / @intToFloat(f32, fb_height),
        0.01,
        200.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // shapes pass
        {
            const vb_info = gctx.lookupResourceInfo(app.gfx.vertex_buffer) orelse unreachable;
            const ib_info = gctx.lookupResourceInfo(app.gfx.index_buffer) orelse unreachable;
            const pipeline = gctx.lookupResource(app.gfx.pipeline) orelse unreachable;
            const bind_group = gctx.lookupResource(app.gfx.bind_group) orelse unreachable;
            const depth_view = gctx.lookupResource(app.gfx.depth_texture_view) orelse unreachable;

            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
            }};
            const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                .view = depth_view,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear_value = 1.0,
            };
            const render_pass_info = wgpu.RenderPassDescriptor{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
                .depth_stencil_attachment = &depth_attachment,
            };

            const pass = encoder.beginRenderPass(render_pass_info);
            defer zgpu.endReleasePass(pass);

            pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
            pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);

            pass.setPipeline(pipeline);

            // Draw triangle 1.
            {
                const object_to_world = zm.identity(); //zm.mul(zm.rotationY(t), zm.translation(-1.0, 0.0, 0.0));
                const object_to_clip = zm.mul(object_to_world, cam_world_to_clip);

                const mem = gctx.uniformsAllocate(zm.Mat, 1);
                mem.slice[0] = zm.transpose(object_to_clip);

                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.drawIndexed(6, 1, 0, 0, 0);
            }

            // Draw triangle 2.
            {
                const object_to_world = zm.mul(zm.rotationY(0.75 * t), zm.translation(1.0, 0.0, 0.0));
                const object_to_clip = zm.mul(object_to_world, cam_world_to_clip);

                const mem = gctx.uniformsAllocate(zm.Mat, 1);
                mem.slice[0] = zm.transpose(object_to_clip);

                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.drawIndexed(6, 1, 0, 0, 0);
            }
        }

        // zgui pass
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, back_buffer_view, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}

pub fn main() !void {
    zglfw.init() catch {
        std.log.err("Failed to initialize GLFW library.", .{});
        return;
    };
    defer zglfw.terminate();

    const window = zglfw.Window.create(1280, 720, "memview", null) catch {
        std.log.err("Failed to create demo window.", .{});
        return;
    };
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = AppContext{
        .allocator = allocator,
        .gfx = try GfxState.init(window, allocator),
        // .gctx = try zgpu.GraphicsContext.create(allocator, window),
        .server = try ServerContext.init(allocator),

        // temp
        .all_messages = std.ArrayList(common.Message).init(allocator),
        .new_messages = std.ArrayList(common.Message).init(allocator),
    };

    defer app.gfx.deinit();
    defer app.server.deinit();

    zgui.init(allocator);
    defer zgui.deinit();

    zgui.backend.initWithConfig(
        window,
        app.gfx.gctx.device,
        @enumToInt(zgpu.GraphicsContext.swapchain_format),
        .{ .texture_filter_mode = .linear, .pipeline_multisample_count = 1 },
    );
    defer zgui.backend.deinit();

    {
        const scale: [2]f32 = window.getContentScale();
        const scale_factor: f32 = std.math.max(scale[0], scale[1]);
        zgui.getStyle().scaleAllSizes(scale_factor);
    }

    try server.spawnThread(&app.server);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        zgui.backend.newFrame(
            app.gfx.gctx.swapchain_descriptor.width,
            app.gfx.gctx.swapchain_descriptor.height,
        );

        try updateMessages(&app);
        updateGui(&app);
        draw(&app);
    }

    server.joinThread(&app.server);
}
