// Local inverse warp, authored against this illustration's 2048 x 1152 layout.
// No extra render target or texture: the existing base-image pass samples once.
uniform sampler2D g_Texture0; // {"hidden":true}
uniform vec4 g_Color4;
uniform float g_Time;
uniform float u_HairEnabled; // {"material":"character_hair_enabled","default":1,"range":[0,1]}
uniform float u_HairStrength; // {"material":"character_hair_strength","default":65,"range":[0,100]}
uniform float u_HairSpeed; // {"material":"character_hair_speed","default":100,"range":[50,150]}
varying vec2 v_TexCoord;

float transition(float y, float a, float b, float from, float to) {
    return mix(from, to, smoothstep(a, b, y));
}
float band(vec2 p, float left, float right, float feather) {
    return smoothstep(left - feather, left + feather, p.x)
         * (1.0 - smoothstep(right - feather, right + feather, p.x));
}
float breeze(float time, float y, float phase) {
    // Slow travelling bend plus a smaller gust; never unbounded translation.
    return 0.78 * sin(time - y * 0.0032 + phase)
         + 0.22 * sin(time * 1.71 - y * 0.0051 + phase + 0.8);
}
void main() {
    vec2 uv = v_TexCoord;
    float strength = clamp(u_HairStrength * 0.01, 0.0, 1.0)
                   * step(0.5, u_HairEnabled);
    if (strength > 0.0) {
        vec2 p = uv * vec2(2048.0, 1152.0);
        float t = g_Time * 0.95 * clamp(u_HairSpeed * 0.01, 0.5, 1.5);
        vec2 movement = vec2(0.0);

        // Left lengths below the flower; the shoulder/hand stay outside.
        float ll = transition(p.y, 455.0, 610.0, 788.0, 713.0);
        ll = transition(p.y, 610.0, 710.0, ll, 716.0);
        ll = transition(p.y, 710.0, 761.0, ll, 756.0);
        float lr = transition(p.y, 455.0, 535.0, 808.0, 784.0);
        lr = transition(p.y, 535.0, 710.0, lr, 782.0);
        lr = transition(p.y, 710.0, 761.0, lr, 767.0);
        float left = band(p, ll, lr, 10.0) * smoothstep(453.0, 575.0, p.y)
                   * (1.0 - smoothstep(731.0, 771.0, p.y));
        float wl = breeze(t, p.y, 0.0);
        movement += left * vec2(6.2 * wl, 0.8 * sin(t * 0.83 + 0.4));

        // Right outer length, carefully following the shoulder silhouette.
        float rl = transition(p.y, 296.0, 430.0, 1145.0, 1165.0);
        rl = transition(p.y, 430.0, 485.0, rl, 1220.0);
        rl = transition(p.y, 485.0, 535.0, rl, 1267.0);
        rl = transition(p.y, 535.0, 600.0, rl, 1283.0);
        rl = transition(p.y, 600.0, 644.0, rl, 1310.0);
        float rr = transition(p.y, 296.0, 425.0, 1185.0, 1270.0);
        rr = transition(p.y, 425.0, 580.0, rr, 1372.0);
        rr = transition(p.y, 580.0, 644.0, rr, 1324.0);
        float right = band(p, rl, rr, 12.0) * smoothstep(295.0, 465.0, p.y)
                    * (1.0 - smoothstep(614.0, 654.0, p.y));
        float wr = breeze(t, p.y, 0.65);
        movement += right * vec2(6.8 * wr, 1.0 * sin(t * 0.83 + 1.2));

        // Lower right locks; keep the arm and foreground flowers pinned.
        float bl = transition(p.y, 635.0, 755.0, 1287.0, 1287.0);
        bl = transition(p.y, 755.0, 871.0, bl, 1302.0);
        float br = transition(p.y, 635.0, 745.0, 1323.0, 1361.0);
        br = transition(p.y, 745.0, 813.0, br, 1348.0);
        br = transition(p.y, 813.0, 897.0, br, 1374.0);
        br = transition(p.y, 897.0, 951.0, br, 1329.0);
        float lower = band(p, bl, br, 10.0) * smoothstep(631.0, 710.0, p.y)
                    * (1.0 - smoothstep(904.0, 950.0, p.y));
        movement += lower * vec2(5.5 * breeze(t, p.y, 0.9), 0.7 * sin(t + 1.7));

        // Restrained fringe motion, separated from eyes, cheek and hat brim.
        vec2 bangLeft = (p - vec2(830.0, 285.0)) / vec2(27.0, 65.0);
        float bangL = (1.0 - smoothstep(0.50, 1.0, dot(bangLeft, bangLeft)))
                    * smoothstep(220.0, 285.0, p.y);
        float bangCenter = transition(p.y, 275.0, 379.0, 1101.0, 1070.0);
        float bangR = band(p, bangCenter - 13.0, bangCenter + 17.0, 9.0)
                    * smoothstep(271.0, 325.0, p.y)
                    * (1.0 - smoothstep(359.0, 390.0, p.y));
        movement += vec2(bangL * 1.1 * breeze(t, p.y, 0.2)
                       + bangR * 1.5 * breeze(t, p.y, 0.8), 0.0);
        uv -= strength * movement / vec2(2048.0, 1152.0);
    }
    gl_FragColor = texSample2D(g_Texture0, uv) * g_Color4;
}
