#version 330 core
in vec2 vert;
out vec4 frag;
uniform sampler2D tex;

void main() {
    // vec2 fragCoord = vert + 0.5;
    vec2 fragCoord = vert * 0.5 + 0.5;
    frag = texture(tex, fragCoord);
}
