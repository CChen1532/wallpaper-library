#include <metal_stdlib>
using namespace metal;
struct Uniforms { uint width; uint height; float time; uint steps; };
constant float PI = 3.14159265359;
float hash21(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float noise(float2 p) {
    float2 i=floor(p), f=fract(p); f=f*f*(3.-2.*f);
    return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x),mix(hash21(i+float2(0,1)),hash21(i+1.),f.x),f.y);
}
float3 sky(float3 d) {
    float2 uv=float2(atan2(d.z,d.x)/(2.*PI),asin(clamp(d.y,-1.,1.))/PI);
    float cloud=noise(uv*8.+2.)*noise(uv*26.);
    float3 c=float3(.0001,.00015,.00025)+cloud*float3(.001,.0015,.003);
    for(int i=0;i<3;i++) {
        float scale=120.+float(i)*113.; float2 q=uv*scale;
        float2 id=floor(q), p=fract(q); float h=hash21(id+float(i)*27.);
        float2 center=float2(hash21(id+7.),hash21(id+13.))*.7+.15;
        float r=length(p-center);
        float star=exp(-r*r*(i==0?950.:1700.))*step(i==0?.98:i==1?.94:.88,h);
        c+=star*(.25+pow(h,35.)*1.8)*mix(float3(.66,.79,1.),float3(1.,.83,.54),hash21(id+19.));
    }
    return c;
}
// Text lives in the accretion plane. The same bent rays sample gas and glyphs,
// so lensing and horizon occlusion also apply to the equations.
float silkHeight(float3 p,float t) {
    float r=length(p.xz), a=atan2(p.z,p.x);
    float fold=sin(r*.59-a*2.+t*.045)*.85 + sin(r*.28+a*3.-t*.035)*.42;
    return fold*smoothstep(3.8,11.,r);
}
float4 disc(float3 p,float t,texture2d<float> atlas) {
    constexpr sampler s(filter::linear,address::clamp_to_zero);
    float r=length(p.xz); if(r<1.65 || r>19.) return 0.;
    float a=atan2(p.z,p.x);
    float rot=a-t*.018/(.3+r*.10);
    float band=noise(float2(r*6.,rot*9.));
    float fil=pow(.5+.5*sin(r*35.+noise(float2(rot*10.,r*.7))*5.-t*.1),10.);
    float spiral=pow(noise(float2(r*2.+rot*2.,rot*17.-t*.06)),3.);
    float edge=smoothstep(1.65,1.9,r)*(1.-smoothstep(16.,19.,r));
    // Continuous inner disc opens into broad, separated silk ribbons outside.
    float ribbon=fract((r-7.+.55*sin(a*2.+t*.025))/3.9);
    float woven=smoothstep(.04,.14,ribbon)*(1.-smoothstep(.66,.83,ribbon));
    edge*=mix(1.,woven,smoothstep(6.,10.,r));
    float heat=pow(3./r,1.8);
    float doppler=clamp(1.+p.x/r*.45,.4,1.5);
    float3 warm=mix(float3(.88,.53,.18),float3(1.,.88,.60),clamp(heat,.0,1.));
    float3 c=warm*(.025+band*.055+fil*.035+spiral*.12)*heat*doppler;
    // Fourteen curved lanes, twenty travelling equations per lane. Each is a
    // separately selected, legible expression rather than random symbols.
    float lane=floor((r-2.5)/1.1);
    float radial=fract((r-2.5)/1.1);
    float angular=(rot/(2.*PI)+.5)*20.+lane*.37;
    float sector=floor(angular), along=fract(angular);
    float glyph=0.;
    if(lane>=0. && lane<15. && radial>.12 && radial<.83 && along>.08 && along<.90) {
        float index=fmod(sector+lane*7.+128.,32.);
        float2 local=float2(1.-(along-.08)/.82,1.-(radial-.12)/.71);
        float2 cell=float2(fmod(index,4.),floor(index/4.));
        glyph=atlas.sample(s,(cell+local)/float2(4.,8.)).r;
    }
    // A fine weave of dim equations sits below the larger travelling formulae.
    float fineRow=floor((r-2.)/.42), fineY=fract((r-2.)/.42);
    float fineAngle=(rot/(2.*PI)+.5)*44.+fineRow*.618;
    float fineX=fract(fineAngle), fineIndex=fmod(floor(fineAngle)+fineRow*11.+512.,32.);
    float micro=0.;
    if(fineY>.12 && fineY<.85 && fineX>.08 && fineX<.94) {
        float2 cell=float2(fmod(fineIndex,4.),floor(fineIndex/4.));
        float2 local=float2(1.-(fineX-.08)/.86,1.-(fineY-.12)/.73);
        micro=atlas.sample(s,(cell+local)/float2(4.,8.)).r;
    }
    c+=float3(1.,.68,.30)*micro*.16;
    c+=float3(1.,.87,.62)*exp(-pow((r-2.15)/.22,2.))*.85;
    c+=float3(1.,.80,.46)*glyph*(.8+heat*1.5)*doppler;
    float opacity=edge*(.22+glyph*.5);
    return float4(c*edge,opacity);
}
kernel void universe(texture2d<float,access::write> dst [[texture(0)]],texture2d<float> atlas [[texture(1)]],constant Uniforms& u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=u.width || gid.y>=u.height)return;
    float2 q=(float2(gid)+.5-float2(u.width,u.height)*.5)/float(u.height);
    q.y=-q.y;
    float roll=-.09+.04*sin(u.time*.018);
    q=float2(cos(roll)*q.x-sin(roll)*q.y,sin(roll)*q.x+cos(roll)*q.y);
    // Gentle autonomous drift. Never depends on mouse or keyboard state.
    float3 eye=float3(0.,3.3+.35*sin(u.time*.026),19.5+.5*cos(u.time*.018));
    float3 forward=normalize(-eye),right=float3(1,0,0),up=normalize(cross(right,forward));
    float3 dir=normalize(forward*1.13+right*q.x+up*q.y);
    float3 p=eye,v=dir,col=0.; float trans=1.; bool swallowed=false;
    float L2=dot(cross(p,v),cross(p,v));
    float minR=100.; float3 prev=p;
    float oldHeight=p.y-silkHeight(p,u.time);
    for(uint i=0;i<u.steps;i++) {
        float r=length(p); minR=min(minR,r);
        if(r<1.02){swallowed=true;break;}
        if(r>34.)break;
        float ds=clamp(r*.09,.055,1.4)*mix(1.,150./float(u.steps),smoothstep(3.,7.,r));
        float3 accel=-1.5*L2*p/pow(r,5.);
        float3 nv=v+accel*ds;
        prev=p; p+=(v+nv)*(.5*ds); v=nv;
        float newHeight=p.y-silkHeight(p,u.time);
        if(oldHeight*newHeight<=0.) {
            float w=oldHeight/(oldHeight-newHeight);
            float4 disk=disc(mix(prev,p,w),u.time,atlas);
            col+=trans*disk.rgb;
            trans*=1.-disk.a;
        }
        oldHeight=newHeight;
    }
    if(!swallowed) col+=trans*sky(normalize(v));
    // Thin photon glow, not a solid ring overlay; the inner silhouette stays black.
    float ring=exp(-pow((minR-1.52)/.12,2.))*.08;
    if(!swallowed) col+=float3(1.,.56,.17)*ring;
    dst.write(float4(col,1.),gid);
}
// A true separable blur avoids repeated, displaced copies of the formula glyphs.
kernel void bloomX(texture2d<float> hdr [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=dst.get_width() || gid.y>=dst.get_height())return;
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 uv=(float2(gid)+.5)/float2(dst.get_width(),dst.get_height());
    float3 c=0.;float total=0.;
    for(int i=-12;i<=12;i++) {
        float w=exp(-float(i*i)/32.);
        c+=max(hdr.sample(s,uv+float2(float(i)/dst.get_width(),0.)).rgb-.65,0.)*w;
        total+=w;
    }
    dst.write(float4(c/total,1.),gid);
}
kernel void bloomY(texture2d<float> src [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=dst.get_width() || gid.y>=dst.get_height())return;
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 uv=(float2(gid)+.5)/float2(dst.get_width(),dst.get_height());
    float3 c=0.;float total=0.;
    for(int i=-12;i<=12;i++) {
        float w=exp(-float(i*i)/32.);
        c+=src.sample(s,uv+float2(0.,float(i)/dst.get_height())).rgb*w;total+=w;
    }
    dst.write(float4(c/total,1.),gid);
}
kernel void finish(texture2d<float,access::read> hdr [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],texture2d<float> bloom [[texture(2)]],constant Uniforms& u [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=u.width || gid.y>=u.height)return;
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float3 c=hdr.read(gid).rgb;
    c+=bloom.sample(s,(float2(gid)+.5)/float2(u.width,u.height)).rgb*.65;
    c*=1.55;
    c=(c*(2.51*c+.03))/(c*(2.43*c+.59)+.14);
    c=pow(clamp(c,0.,1.),float3(1./2.2));
    dst.write(float4(c,1.),gid);
}
struct VOut { float4 position [[position]];float2 uv; };
vertex VOut fullscreen(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2);
    return {float4(p*2.-1.,0,1),float2(p.x,1.-p.y)};
}
fragment float4 present(VOut in [[stage_in]],texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge); return tex.sample(s,in.uv);
}
