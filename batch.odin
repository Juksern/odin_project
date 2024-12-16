package main

import d3d "vendor:directx/d3d11"

import "core:fmt"
import "base:runtime"

MAX_VERTICES :: 2048

vertex :: struct {
    pos: [3]f32,
    color: [3]f32
}

batch :: struct {
    size: int,
    topology: d3d.PRIMITIVE_TOPOLOGY
}

render_queue :: struct {
    vertices: [dynamic]vertex,
    batches: [dynamic]batch,
}

add_vertice :: proc(queue: ^render_queue, v: vertex, top: d3d.PRIMITIVE_TOPOLOGY) {
    assert(top != .LINESTRIP)
    assert(top != .LINESTRIP_ADJ)
    assert(top != .TRIANGLESTRIP)
    assert(top != .TRIANGLESTRIP_ADJ)
    assert(len(queue.vertices) + 1 < MAX_VERTICES, "We should probably increase vertex buffer size")

    if len(queue.batches) == 0 || queue.batches[len(queue.batches) - 1].topology != top {
        append(&queue.batches, batch{size = 0, topology = top})
    }

    queue.batches[len(queue.batches) - 1].size += 1
    append(&queue.vertices, v)
}

add_vertices :: proc(queue: ^render_queue, v: []vertex, top: d3d.PRIMITIVE_TOPOLOGY) {
    assert(len(queue.vertices) + len(v) < MAX_VERTICES, "We should probably increase vertex buffer size")

    if len(queue.batches) == 0 || queue.batches[len(queue.batches) - 1].topology != top {
        append(&queue.batches, batch{size = 0, topology = top})
    }

    queue.batches[len(queue.batches) - 1].size += len(v)
    resize(&queue.vertices, len(queue.vertices) + len(v))

    #reverse for vert, i in v {
        queue.vertices[len(queue.vertices) - i - 1] = vert
    }

    #partial switch(top)  {
        case .LINESTRIP:
            fallthrough
        case .LINESTRIP_ADJ:
            fallthrough
        case .TRIANGLESTRIP:
            fallthrough
        case .TRIANGLESTRIP_ADJ:
            seperator := vertex{}
            add_vertice(queue, seperator, .UNDEFINED)
        case:
            break
    }
}

draw_line :: proc(queue: ^render_queue, from, to: [2]f32, color: [3]f32) {
    vertices := [?]vertex {
        {{from.x, from.y, 0}, color},
        {{to.x, to.y, 0}, color},
    }

    add_vertices(queue, vertices[:], .LINELIST)
}

draw_filled_rect :: proc(queue: ^render_queue, rect: [4]f32, color: [3]f32) {
    vertices := [?]vertex {
        {{rect.x,   rect.y,                   0}, color},
        {{rect.x +  rect.z,  rect.y,          0}, color},
        {{rect.x,   rect.y + rect.w,          0}, color},

        {{rect.x +  rect.z,	 rect.y,          0}, color},
        {{rect.x +  rect.z,	 rect.y + rect.w, 0}, color},
        {{rect.x,   rect.y + rect.w,          0}, color},
    }

    add_vertices(queue, vertices[:], .TRIANGLELIST)
}

draw_bordered_rect :: proc(queue: ^render_queue, rect: [4]f32, color: [3]f32) {
    vertices := [?]vertex {
        {{rect.x,               rect.y,          0}, color},
        {{rect.x +  rect.w,     rect.y,          0}, color},
        {{rect.x +  rect.w,     rect.y + rect.z, 0}, color},
        {{rect.x,   rect.y +    rect.z,          0}, color},
    }

    line_vertices := [?]vertex {
        vertices[0], vertices[1],
        vertices[1], vertices[2],
        vertices[2], vertices[3],
        vertices[3], vertices[0],
    }

    add_vertices(queue, line_vertices[:], .LINELIST)
}

draw_scene :: proc(queue: ^render_queue, ctx: ^d3d.IDeviceContext, vb: ^d3d.IBuffer) {
    if len(queue.vertices) > 0 {
        mapped: d3d.MAPPED_SUBRESOURCE

        ctx->Map(vb, 0, .WRITE_DISCARD, {}, &mapped)
        runtime.mem_copy(mapped.pData, raw_data(queue.vertices), size_of(vertex) * len(queue.vertices))
        ctx->Unmap(vb, 0)
    }

    pos := 0
    for batch in queue.batches {
        ctx->IASetPrimitiveTopology(batch.topology)
        ctx->Draw(u32(batch.size), u32(pos))

        pos += batch.size
    }

    clear(&queue.batches)
    clear(&queue.vertices)
}