package main

import d3d "vendor:directx/d3d11"
import dx "vendor:directx/dxgi"
import compiler "vendor:directx/d3d_compiler"

import os2 "core:os/os2"

import glsl "core:math/linalg/glsl"
import fmt "core:fmt"
import win "core:sys/windows"

import "core:math"
import "core:mem"

import "base:runtime"

window_running := true

vs_hlsl := `
struct VSInput
{
    float3 position: POSITION;
    float3 color: COLOR0;
};

struct VSOutput
{
    float4 position: SV_Position;
    float3 color: COLOR0;
};

VSOutput Main(VSInput input)
{
    VSOutput output = (VSOutput)0;
    output.position = float4(input.position, 1.0);
    output.color = input.color;
    return output;
}
`

ps_hlsl := `
struct PSInput
{
    float4 position: SV_Position;
    float3 color: COLOR0;
};

struct PSOutput
{
    float4 color: SV_Target0;
};

PSOutput Main(PSInput input)
{
    PSOutput output = (PSOutput)0;
    output.color = float4(input.color, 1.0);
    return output;
}
`

matrix_perspective_01 :: proc (fovy, aspect, near, far: f32) -> matrix[4,4]f32 {
    y_scale       := 1 / math.tan(fovy * 0.5)
    x_scale       := y_scale / aspect
    z_scale       := near / (near - far)
    z_translation := -far * z_scale

    return matrix[4,4]f32 {
            x_scale, 0, 0, 0,
            0, y_scale, 0, 0,
            0, 0, z_scale, z_translation,
            0, 0, 1, 0
    }
}


winproc :: proc "stdcall" (window: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
    result: win.LRESULT

    switch message {
        case win.WM_CLOSE:
            fallthrough
        case win.WM_DESTROY:
            window_running = false
            win.DestroyWindow(window)
            win.PostQuitMessage(0)
        case:
            result = win.DefWindowProcW(window, message, wparam, lparam)
    }

    return result
}

create_device :: proc (hwnd: win.HWND) -> (^dx.ISwapChain, ^d3d.IDevice, ^d3d.IDeviceContext){
    result : win.HRESULT

    feature_levels := [?]d3d.FEATURE_LEVEL{._11_0}

    description := dx.SWAP_CHAIN_DESC {
        BufferDesc = {
            Width = 0,
            Height = 0,
            RefreshRate = {144, 1},
            Format = .B8G8R8A8_UNORM,
            ScanlineOrdering = .UNSPECIFIED,
            Scaling = .STRETCHED
        },
        SampleDesc = {
            Count = 1,
            Quality = 0,
        },
        BufferUsage = {.RENDER_TARGET_OUTPUT},
        BufferCount = 2,
        OutputWindow = hwnd,
        Windowed = win.TRUE,
        SwapEffect = .FLIP_DISCARD,
        Flags = {},
    }

    swapchain : ^dx.ISwapChain
    device : ^d3d.IDevice
    ctx : ^d3d.IDeviceContext

    result = d3d.CreateDeviceAndSwapChain(
        nil,
        .HARDWARE,
        nil,
        {(.BGRA_SUPPORT | .DEBUG)},
        &feature_levels[0],
        len(feature_levels),
        d3d.SDK_VERSION,
        &description,
        &swapchain,
        &device,
        nil,
        &ctx
    )

    if result < 0 {
        fmt.printfln("Failed to CreateDeviceAndSwapchain: {}", win.HRESULT(result))
    }

    return swapchain, device, ctx
}

create_essentials :: proc(device: ^d3d.IDevice, swapchain: ^dx.ISwapChain) -> (back_buffer, depth_buffer: ^d3d.ITexture2D, render_target_view: ^d3d.IRenderTargetView, depth_stencil_view: ^d3d.IDepthStencilView) {
    m_back_buffer : ^d3d.ITexture2D
    m_depth_buffer: ^d3d.ITexture2D
    m_rendertargetview : ^d3d.IRenderTargetView
    m_depthstencilview : ^d3d.IDepthStencilView

    //back buffer & render target view
    swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&m_back_buffer))
    device->CreateRenderTargetView(m_back_buffer, nil, &m_rendertargetview)

    //depth buffer
    depth_desc : d3d.TEXTURE2D_DESC
    m_back_buffer->GetDesc(&depth_desc)
    depth_desc.Format = .D24_UNORM_S8_UINT
    depth_desc.BindFlags = {.DEPTH_STENCIL}
    device->CreateTexture2D(&depth_desc, nil, &m_depth_buffer)

    //depth stencil view
    device->CreateDepthStencilView(m_depth_buffer, nil, &m_depthstencilview)

    return m_back_buffer, m_depth_buffer, m_rendertargetview, m_depthstencilview
}

create_states :: proc(device: ^d3d.IDevice) -> (depth_stencil_state: ^d3d.IDepthStencilState, rasterizer_state: ^d3d.IRasterizerState, sampler_state: ^d3d.ISamplerState) {
    m_depth_stencil_state: ^d3d.IDepthStencilState
    m_rasterizer_state: ^d3d.IRasterizerState
    m_sampler_state: ^d3d.ISamplerState

    depth_stencil_desc := d3d.DEPTH_STENCIL_DESC{
        DepthEnable = true,
        DepthWriteMask = .ALL,
        DepthFunc = .LESS
    }
    device->CreateDepthStencilState(&depth_stencil_desc, &m_depth_stencil_state)

    rasterizer_desc := d3d.RASTERIZER_DESC {
        FillMode = .SOLID,
        CullMode = .BACK
    }
    device->CreateRasterizerState(&rasterizer_desc, &m_rasterizer_state)

    sampler_desc := d3d.SAMPLER_DESC {
        Filter = .MIN_MAG_MIP_POINT,
        AddressU = .WRAP,
        AddressV = .WRAP,
        AddressW = .WRAP,
        ComparisonFunc = .NEVER
    }
    device->CreateSamplerState(&sampler_desc, &m_sampler_state)

    return m_depth_stencil_state, m_rasterizer_state, m_sampler_state
}

@(link_name="mainCRTStartup", linkage="strong", require)
mainCRTStartup :: proc "system" (hInstance, hPrevInstance: win.HINSTANCE, lpCmdLine: win.LPSTR, nCmdShow: win.INT) -> i32 {
    return i32(WinMain(hInstance, hPrevInstance, lpCmdLine, nCmdShow))
}

WinMain :: proc "system" (hInstance, hPrevInstance: win.HINSTANCE, lpCmdLine: win.LPSTR, nCmdShow: win.INT) -> win.LRESULT {
    context = runtime.default_context()
    main_proc(hInstance)
    return 0
}

main_proc :: proc(hinst: win.HINSTANCE) {
    window_class := win.WNDCLASSEXW {
        size_of(win.WNDCLASSEXW),
        win.CS_HREDRAW | win.CS_VREDRAW,
        winproc,
        0,
        0,
        hinst,
        nil,
        win.LoadCursorW(hinst, win.L("IDC_ARROW")),
        nil,
        nil,
        win.L("render-window"),
        nil
    }

    if error := win.RegisterClassExW(&window_class); error == 0 {
        fmt.println("failed to register window class")
    }
    defer win.UnregisterClassW(win.L("render-window"), hinst)

    window_hwnd := win.CreateWindowExW(
        0,
        win.L("render-window"),
        win.L("hello"),
        win.WS_OVERLAPPEDWINDOW,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        1280,
        720,
        nil,
        nil,
        hinst,
        nil
    )
    defer win.DestroyWindow(window_hwnd)

    if window_hwnd == nil {
        fmt.println("failed to create window")
        return
    }

    swapchain, device, ctx := create_device(window_hwnd)
    defer device->Release()
    defer swapchain->Release()
    defer ctx->Release()

    back_buffer, depth_buffer, render_target_view, depth_stencil_view := create_essentials(device, swapchain)
    defer back_buffer->Release()
    defer render_target_view->Release()
    defer depth_buffer->Release()
    defer depth_stencil_view->Release()

    depth_stencil_state, rasterizer_state, sampler_state := create_states(device)
    defer depth_stencil_state->Release()
    defer rasterizer_state->Release()
    defer sampler_state->Release()

    queue: render_queue
    reserve(&queue.batches, 512)
    reserve(&queue.vertices, MAX_VERTICES)

    ///////////////////////////////////////////////////////////////////
    buffer_desc := d3d.BUFFER_DESC {
        ByteWidth = size_of(vertex) * u32(MAX_VERTICES),
        Usage = .DYNAMIC,
        BindFlags = {.VERTEX_BUFFER},
        CPUAccessFlags = {.WRITE}
    }

    vertex_buffer : ^d3d.IBuffer
    if result := device->CreateBuffer(&buffer_desc, nil, &vertex_buffer); result < 0 {
        fmt.printfln("failed to create vertex_buffer: {}", win.HRESULT(result))
        return
    }
    defer vertex_buffer->Release()

    ///////////////////////////////////////////////////////////////////
    vs_blob: ^d3d.IBlob
    vs_error_blob: ^d3d.IBlob
    if result := compiler.Compile(raw_data(vs_hlsl), len(vs_hlsl), "vs.hlsl", nil, nil, "Main", "vs_5_0", 0, 0, &vs_blob, &vs_error_blob); result < 0 {
        fmt.printfln("failed to compile vertex shader: {} {}", win.HRESULT(result), vs_error_blob->GetBufferPointer())
        defer vs_error_blob->Release()
        return
    }
    defer vs_blob->Release()

    vertex_shader: ^d3d.IVertexShader
    device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &vertex_shader)
    defer vertex_shader->Release()

    ///////////////////////////////////////////////////////////////////
    ps_blob: ^d3d.IBlob
    ps_error_blob: ^d3d.IBlob
    if result := compiler.Compile(raw_data(ps_hlsl), len(ps_hlsl), "ps.hlsl", nil, nil, "Main", "ps_5_0", 0, 0, &ps_blob, &ps_error_blob); result < 0 {
        fmt.printfln("failed to compile pixel shader: {} {}", win.HRESULT(result), ps_error_blob->GetBufferPointer())
        defer ps_error_blob->Release()
        return
    }
    defer ps_blob->Release()

    pixel_shader: ^d3d.IPixelShader
    device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &pixel_shader)
    defer pixel_shader->Release()

    ///////////////////////////////////////////////////////////////////
    layout := [?]d3d.INPUT_ELEMENT_DESC {
        {"POSITION",     0, .R32G32B32_FLOAT,    0,       0,                          .VERTEX_DATA, 0},
        {"COLOR",        0, .R32G32B32_FLOAT,    0,       d3d.APPEND_ALIGNED_ELEMENT, .VERTEX_DATA, 0}
    }

    input_layout: ^d3d.IInputLayout
    device->CreateInputLayout(&layout[0], len(layout), vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &input_layout)
    defer input_layout->Release()

    win.ShowWindow(window_hwnd, win.SW_SHOW)

    viewport := d3d.VIEWPORT {
        TopLeftX = 0,
        TopLeftY = 0,
        Width = 1280,
        Height = 720,
        MinDepth = 0.0,
        MaxDepth = 1.0,
    }

    msg : win.MSG
    for window_running {
        if win.PeekMessageA(&msg, window_hwnd, 0, 0, win.PM_REMOVE) {
            win.TranslateMessage(&msg)
            win.DispatchMessageW(&msg)
        } else {
            ctx->ClearRenderTargetView(render_target_view, &[4]f32{0.0, 0.0, 0.0, 1.0})
            ctx->ClearDepthStencilView(depth_stencil_view, {(.DEPTH | .STENCIL)}, 1.0, 0)

            ctx->RSSetState(rasterizer_state)
            ctx->PSSetSamplers(0, 1, &sampler_state)

            ctx->OMSetRenderTargets(1, &render_target_view, nil)
            ctx->OMSetDepthStencilState(depth_stencil_state, 0)
            ctx->OMSetBlendState(nil, nil, 0xffffffff)
            ctx->IASetInputLayout(input_layout)

            ctx->RSSetViewports(1, &viewport)

            ctx->VSSetShader(vertex_shader, nil, 0)
            ctx->PSSetShader(pixel_shader, nil, 0)

            stride : u32 = size_of(vertex)
            offset : u32 = 0
            ctx->IASetVertexBuffers(0, 1, &vertex_buffer, &stride, &offset)

            add_vertice(&queue, {{-0.5,  0.5,   1}, {1, 0, 1}}, .TRIANGLELIST)
            add_vertice(&queue, {{0.5,  -0.5,   1}, {1, 1, 0}}, .TRIANGLELIST)
            add_vertice(&queue, {{-0.5, -0.5,   1}, {1, 1, 0}}, .TRIANGLELIST)
            add_vertice(&queue, {{-0.5,  0.5,   1}, {1, 0, 1}}, .TRIANGLELIST)
            add_vertice(&queue, {{0.5,   0.5,   1}, {0, 1, 1}}, .TRIANGLELIST)
            add_vertice(&queue, {{0.5,  -0.5,   1}, {1, 1, 0}}, .TRIANGLELIST)

            draw_scene(&queue, ctx, vertex_buffer)

            swapchain->Present(1, {})
        }
    }
}