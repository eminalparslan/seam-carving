#version 330 core
out vec2 vert;

void main() {
    const vec4 vertices[4] = vec4[4](
        vec4(-1.0, -1.0, 0.0, 1.0),
        vec4( 1.0, -1.0, 0.0, 1.0),
        vec4(-1.0,  1.0, 0.0, 1.0),
        vec4( 1.0,  1.0, 0.0, 1.0)
    );
    // const vec4 vertices[4] = vec4[4](
    //     vec4(-0.5, -0.5, 0.0, 1.0),
    //     vec4( 0.5, -0.5, 0.0, 1.0),
    //     vec4(-0.5,  0.5, 0.0, 1.0),
    //     vec4( 0.5,  0.5, 0.0, 1.0)
    // );
    vert = vec2(vertices[gl_VertexID].x, vertices[gl_VertexID].y);
    gl_Position = vertices[gl_VertexID];
}
