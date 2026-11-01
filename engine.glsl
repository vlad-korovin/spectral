//#MESH_VERTEX_SHADER

layout (location = 0) in vec3 aPosition;
layout (location = 1) in vec3 aNormal;

// Per-instance rigid model matrix.
layout (location = 2) in vec4 iModel0;
layout (location = 3) in vec4 iModel1;
layout (location = 4) in vec4 iModel2;
layout (location = 5) in vec4 iModel3;

layout (location = 6) in float iOpticalLOD;

uniform mat4 uView;
uniform mat4 uProjection;
uniform vec3 uCameraPosition;

out vec3 vWorldPosition;
out vec3 vWorldNormal;

out vec3 vObjectPosition;
out vec3 vObjectNormal;

flat out vec3 vCameraObjectPosition;

flat out vec3 vBasisX;
flat out vec3 vBasisY;
flat out vec3 vBasisZ;

flat out float vOpticalLOD;
flat out int vInstanceID;

void main()
{
    mat4 model = mat4(iModel0, iModel1, iModel2, iModel3);

    mat3 rotation = mat3(model);

    vec3 translation = iModel3.xyz;

    vec4 worldPosition = model *
        vec4(aPosition, 1.0);

    vWorldPosition = worldPosition.xyz;

    vWorldNormal = normalize(rotation *
        aNormal);

    vObjectPosition = aPosition;

    vObjectNormal = aNormal;

    // --------------------------------------------------------
    // Rigid inverse:
    //
    // objectCamera =
    // transpose(R) * (worldCamera - translation)
    // --------------------------------------------------------

    vCameraObjectPosition = transpose(rotation) *
        (uCameraPosition -
        translation);

    // World-space basis used later to transform exit rays.
    vBasisX = iModel0.xyz;

    vBasisY = iModel1.xyz;

    vBasisZ = iModel2.xyz;

    vOpticalLOD = iOpticalLOD;
    vInstanceID = gl_InstanceID;

    gl_Position = uProjection *
        uView *
        worldPosition;
}

//#FULLSCREEN_VERTEX_SHADER

layout (location = 0) in vec2 aPosition;

void main()
{
    gl_Position = vec4(aPosition, 0.0, 1.0);
}

//#SCENE_FRAGMENT_SHADER

in vec3 vWorldPosition;
in vec3 vWorldNormal;

in vec3 vObjectPosition;
in vec3 vObjectNormal;

flat in vec3 vCameraObjectPosition;

flat in vec3 vBasisX;
flat in vec3 vBasisY;
flat in vec3 vBasisZ;

flat in float vOpticalLOD;
flat in int vInstanceID;

out vec4 fragColor;

uniform sampler2D uSceneColor;
uniform int uUseSceneColor;
uniform sampler2D uEnvironment;

uniform mat4 uView;
uniform vec2 uResolution;

uniform vec3 uCameraPosition;

uniform float uRefractiveIndex;
uniform float uDispersionC;
uniform float uAbsorptionStrength;

uniform int uDebugMode;

const vec3 LIGHT_POSITION = vec3(3.0, 4.0, 5.0);

float rayPlane(
    vec3 rayOrigin,
    vec3 rayDirection,
    vec3 planePoint,
    vec3 planeNormal
)
{
    float denominator = dot(rayDirection, planeNormal);

    if (abs(denominator) < 0.00001)
        return -1.0;

    return dot(planePoint - rayOrigin, planeNormal) / denominator;
}

bool insideTriangle(
    vec3 p,
    vec3 a,
    vec3 b,
    vec3 c
)
{
    vec3 v0 = b - a;
    vec3 v1 = c - a;
    vec3 v2 = p - a;

    float dot00 = dot(v0, v0);
    float dot01 = dot(v0, v1);
    float dot02 = dot(v0, v2);
    float dot11 = dot(v1, v1);
    float dot12 = dot(v1, v2);

    float denominator = dot00 * dot11 -
        dot01 * dot01;

    if (abs(denominator) < 0.00001)
        return false;

    float u = (dot11 * dot02 -
        dot01 * dot12) /
        denominator;

    float v = (dot00 * dot12 -
        dot01 * dot02) /
        denominator;

    return u >= 0.0 &&
        v >= 0.0 &&
        u + v <= 1.0;
}

float findExitDistance(
    vec3 origin,
    vec3 direction,
    out vec3 exitNormal
)
{
    float closest = 1000000.0;
    exitNormal = vec3(0.0);

    vec3 A = vec3(-0.9, -0.7, 0.0);
    vec3 B = vec3(0.9, -0.7, 0.0);
    vec3 C = vec3(0.0, 0.9, 0.0);

    vec3 AFront = vec3(A.x, A.y, 0.7);
    vec3 BFront = vec3(B.x, B.y, 0.7);
    vec3 CFront = vec3(C.x, C.y, 0.7);

    vec3 ABack = vec3(A.x, A.y, -0.7);
    vec3 BBack = vec3(B.x, B.y, -0.7);
    vec3 CBack = vec3(C.x, C.y, -0.7);

    // --------------------------------------------------------
    // Front cap
    // --------------------------------------------------------

    float t = rayPlane(origin, direction, AFront, vec3(0.0, 0.0, 1.0));

    if (t > 0.0001)
    {
        vec3 p = origin + direction * t;

        if (insideTriangle(p, AFront, BFront, CFront))
        {
            closest = t;
            exitNormal = vec3(0.0, 0.0, 1.0);
        }
    }

    // --------------------------------------------------------
    // Back cap
    // --------------------------------------------------------

    t = rayPlane(origin, direction, ABack, vec3(0.0, 0.0, -1.0));

    if (t > 0.0001)
    {
        vec3 p = origin + direction * t;

        if (insideTriangle(p, ABack, CBack, BBack))
        {
            if (t < closest)
            {
                closest = t;
                exitNormal = vec3(0.0, 0.0, -1.0);
            }
        }
    }

    // --------------------------------------------------------
    // Bottom face
    // --------------------------------------------------------

    vec3 bottomNormal = vec3(0.0, -1.0, 0.0);

    t = rayPlane(origin, direction, A, bottomNormal);

    if (t > 0.0001)
    {
        vec3 p = origin + direction * t;

        if (p.x >= -0.9 &&
            p.x <= 0.9 &&
            p.z >= -0.7 &&
            p.z <= 0.7)
        {
            if (t < closest)
            {
                closest = t;
                exitNormal = bottomNormal;
            }
        }
    }

    // --------------------------------------------------------
    // Left sloping face
    // --------------------------------------------------------

    vec3 leftNormal = normalize(vec3(-1.6, 0.9, 0.0));

    t = rayPlane(origin, direction, A, leftNormal);

    if (t > 0.0001)
    {
        vec3 p = origin + direction * t;

        if (p.y >= -0.7 &&
            p.y <= 0.9 &&
            p.z >= -0.7 &&
            p.z <= 0.7)
        {
            if (t < closest)
            {
                closest = t;
                exitNormal = leftNormal;
            }
        }
    }

    // --------------------------------------------------------
    // Right sloping face
    // --------------------------------------------------------

    vec3 rightNormal = normalize(vec3(1.6, 0.9, 0.0));

    t = rayPlane(origin, direction, B, rightNormal);

    if (t > 0.0001)
    {
        vec3 p = origin + direction * t;

        if (p.y >= -0.7 &&
            p.y <= 0.9 &&
            p.z >= -0.7 &&
            p.z <= 0.7)
        {
            if (t < closest)
            {
                closest = t;
                exitNormal = rightNormal;
            }
        }
    }

    return closest;
}

vec3 safeRefract(
    vec3 incident,
    vec3 normal,
    float eta,
    out bool totalInternalReflection
)

{
    float cosTheta = clamp(dot(-incident, normal), -1.0, 1.0);

    float sinTheta2 = eta * eta *
        max(0.0, 1.0 - cosTheta * cosTheta);

    totalInternalReflection = sinTheta2 > 1.0;

    if (totalInternalReflection)
        return reflect(incident, normal);

    return refract(incident, normal, eta);
}

const float PI = 3.14159265358979323846;

vec2 directionToEquirectUV(
    vec3 direction
)
{
    vec3 d = normalize(direction);

    float longitude = atan(d.z, d.x);

    float latitude = asin(clamp(d.y, -1.0, 1.0));

    vec2 uv;

    uv.x = longitude /
        (2.0 * PI) +
        0.5;

    // Image row 0 is the top of the HDR file.
    uv.y = 0.5 -
        latitude /
        PI;

    return uv;
}

vec3 sampleHDRI(
    vec3 direction
)
{
    vec2 uv = directionToEquirectUV(direction);

    // A small optical footprint prevents wavelength-separated HDR texels from
    // turning into colored pixel noise while retaining studio-light structure.
    return textureLod(uEnvironment, uv, 1.0).rgb;
}

vec3 sampleEnvironment(vec3 direction)
{
    vec3 d = normalize(direction);

    // Sky / ground gradient.
    float skyAmount = smoothstep(-0.25, 0.65, d.y);

    vec3 groundColor = vec3(0.035, 0.025, 0.020);

    vec3 horizonColor = vec3(0.32, 0.38, 0.46);

    vec3 skyColor = vec3(0.08, 0.20, 0.42);

    vec3 environment = mix(groundColor, horizonColor, skyAmount);

    environment = mix(environment, skyColor, smoothstep(0.15, 0.95, d.y));

    // Bright directional light source.
    vec3 sunDirection = normalize(vec3(-0.45, 0.55, 0.70));

    float sun = pow(max(dot(d, sunDirection), 0.0), 350.0);

    environment += vec3(7.0, 5.5, 3.5) *
        sun;

    // --------------------------------------------------------
    // Soft studio light.
    // Smooth angular lobe.
    // --------------------------------------------------------

    vec3 studioDirection = normalize(vec3(-0.65, 0.15, 0.75));

    float studio = pow(max(dot(d, studioDirection), 0.0), 18.0);

    environment += vec3(2.2, 2.0, 1.8) *
        studio;

    return environment;
}

vec2 directionSlope(
    vec3 direction
)
{
    float depth = max(abs(direction.z), 0.15);

    return direction.xy /
        depth;
}

// Hero uses bounded internal transport for the view ray as well as for illumination.
// Three display-channel view rays are an approximation; receiver illumination uses 31 wavelengths.
uniform mat4 uProjection;
uniform vec3 uReceiverOrigin;
uniform vec3 uReceiverNormal;
uniform vec3 uReceiverU;
uniform vec3 uReceiverV;
uniform float uReceiverExtent;
vec3 toWorldVector(vec3 d){return vBasisX*d.x+vBasisY*d.y+vBasisZ*d.z;}
vec3 toWorldPoint(vec3 p){return vWorldPosition+toWorldVector(p-vObjectPosition);}
vec3 receiverOrEnvironment(vec3 p,vec3 d){
 float den=dot(d,uReceiverNormal);
 if(den<-.00001){float t=dot(uReceiverOrigin-p,uReceiverNormal)/den;
  vec3 hit=p+d*t,q=hit-uReceiverOrigin;
  if(t>0&&abs(dot(q,uReceiverU))<uReceiverExtent&&abs(dot(q,uReceiverV))<uReceiverExtent){
   vec4 clip=uProjection*uView*vec4(hit,1);vec2 uv=clip.xy/clip.w*.5+.5;
   if(clip.w>0&&all(greaterThan(uv,vec2(0)))&&all(lessThan(uv,vec2(1))))return texture(uSceneColor,uv).rgb;
  }
 }
 return sampleHDRI(d);
}
float dielectricFresnel(float cosine,float n1,float n2){float c=clamp(cosine,0,1),s=n1/n2*sqrt(max(0.,1-c*c));if(s>=1)return 1.;float ct=sqrt(1-s*s);float rs=(n1*c-n2*ct)/(n1*c+n2*ct),rp=(n2*c-n1*ct)/(n2*c+n1*ct);return .5*(rs*rs+rp*rp);}
vec3 heroGlass(){
 vec3 incident=normalize(vObjectPosition-vCameraObjectPosition),normal=normalize(vObjectNormal);
 if(dot(incident,normal)>0)normal=-normal;
 vec3 reflected=sampleHDRI(normalize(toWorldVector(reflect(incident,normal))));
 vec3 result=vec3(0);float wavelengths[3]=float[3](.660,.550,.440);
 for(int channel=0;channel<3;++channel){
  float n=uRefractiveIndex+uDispersionC/(wavelengths[channel]*wavelengths[channel]);
  float f=dielectricFresnel(-dot(incident,normal),1.,n);
  result[channel]=reflected[channel]*f;
  vec3 d=refract(incident,normal,1/n),p=vObjectPosition+d*.0002;
  float throughput=1-f;
  for(int bounce=0;bounce<8;++bounce){
   vec3 outward;float t=findExitDistance(p,d,outward);if(t>99999.)break;
   p+=d*t;throughput*=exp(-.025*uAbsorptionStrength*t);
   vec3 outgoing=refract(d,-outward,n);
   if(dot(outgoing,outgoing)>.001){
    throughput*=1-dielectricFresnel(dot(d,outward),n,1.);
    vec3 radiance=receiverOrEnvironment(toWorldPoint(p),normalize(toWorldVector(outgoing)));
    result[channel]+=radiance[channel]*throughput;break;
   }
   d=reflect(d,outward);p+=d*.0002;
  }
 }
 return max(result,0.);
}

void main()
{
    if(uUseSceneColor!=0 && uDebugMode==0){fragColor=vec4(heroGlass(),1);return;}

    vec3 N = normalize(vWorldNormal);
    vec3 L = normalize(LIGHT_POSITION - vWorldPosition);
    vec3 V = normalize(uCameraPosition - vWorldPosition);

    // ============================================================
    // FAR-FIELD OPTICAL LOD
    //
    // Distant prisms skip:
    // - 3 wavelength refractions
    // - 3 volume intersections
    // - 3 exit refractions
    // - wavelength-dependent optical path integration
    //
    // Debug modes always force full optics.
    // ============================================================

    if (vOpticalLOD > 0.5 &&
        uDebugMode != 5)
    {
        vec3 incident = normalize(vWorldPosition -
            uCameraPosition);

        vec3 reflected = reflect(incident, N);

        vec3 reflectedEnvironment = sampleEnvironment(reflected);

        float cosTheta = max(dot(N, V), 0.0);

        float f0 = pow((uRefractiveIndex - 1.0) /
            (uRefractiveIndex + 1.0), 2.0);

        float fresnel = f0 +
            (1.0 - f0) *
            pow(1.0 - cosTheta, 5.0);

        vec3 cheapTransmission = sampleEnvironment(incident);

        vec3 cheapColor = cheapTransmission *
            (1.0 - fresnel) +
            reflectedEnvironment *
            fresnel;

        fragColor = vec4(cheapColor, 1.0);

        return;
    }

    // --------------------------------------------------------
    // Camera ray in world space
    // --------------------------------------------------------

    vec3 rayOriginWorld = uCameraPosition;

    vec3 rayDirectionWorld = normalize(vWorldPosition -
        rayOriginWorld);

    // --------------------------------------------------------
    // Transform camera ray into prism object space.
    //
    // Point    -> w = 1
    // Direction -> w = 0
    // --------------------------------------------------------

    vec3 rayOriginObject = vCameraObjectPosition;

    vec3 entryPointObject = vObjectPosition;

    vec3 rayDirectionObject = normalize(entryPointObject -
        rayOriginObject);

    const vec3 wavelength = vec3(0.660, 0.550, 0.440);

    vec3 refractiveIndex = uRefractiveIndex +
        uDispersionC /
        (wavelength * wavelength);

    // --------------------------------------------------------
    // Surface normal in object space
    // --------------------------------------------------------

    vec3 entryNormalObject = normalize(vObjectNormal);

    if (dot(rayDirectionObject, entryNormalObject) > 0.0)
    {
        entryNormalObject = -entryNormalObject;
    }

    // The rasterized surface is our entry point.
    // The ray is traveling from air into glass.
    // --------------------------------------------------------

    bool tirEntryR;
    bool tirEntryG;
    bool tirEntryB;

    vec3 refractedR = safeRefract(rayDirectionObject, entryNormalObject, 1.0 / refractiveIndex.r, tirEntryR);

    vec3 refractedG = safeRefract(rayDirectionObject, entryNormalObject, 1.0 / refractiveIndex.g, tirEntryG);

    vec3 refractedB = safeRefract(rayDirectionObject, entryNormalObject, 1.0 / refractiveIndex.b, tirEntryB);

    vec3 exitNormalR;
    vec3 exitNormalG;
    vec3 exitNormalB;

    float exitDistanceR = findExitDistance(entryPointObject, refractedR, exitNormalR);

    float exitDistanceG = findExitDistance(entryPointObject, refractedG, exitNormalG);

    float exitDistanceB = findExitDistance(entryPointObject, refractedB, exitNormalB);

    bool validExitR = exitDistanceR < 999999.0;

    bool validExitG = exitDistanceG < 999999.0;

    bool validExitB = exitDistanceB < 999999.0;

    if (!validExitR)
        exitNormalR = -refractedR;

    if (!validExitG)
        exitNormalG = -refractedG;

    if (!validExitB)
        exitNormalB = -refractedB;

    if (dot(refractedR, exitNormalR) > 0.0)
    {
        exitNormalR = -exitNormalR;
    }

    if (dot(refractedG, exitNormalG) > 0.0)
    {
        exitNormalG = -exitNormalG;
    }

    if (dot(refractedB, exitNormalB) > 0.0)
    {
        exitNormalB = -exitNormalB;
    }

    vec3 exitPointR = validExitR ? entryPointObject +
        refractedR * exitDistanceR : entryPointObject;

    vec3 exitPointG = validExitG ? entryPointObject +
        refractedG * exitDistanceG : entryPointObject;

    vec3 exitPointB = validExitB ? entryPointObject +
        refractedB * exitDistanceB : entryPointObject;

    float opticalLengthR = validExitR ? min(length(exitPointR -
        entryPointObject), 4.0) : 0.0;

    float opticalLengthG = validExitG ? min(length(exitPointG -
        entryPointObject), 4.0) : 0.0;

    float opticalLengthB = validExitB ? min(length(exitPointB -
        entryPointObject), 4.0) : 0.0;

    // --------------------------------------------------------
    // Beer-Lambert absorption.
    //
    // T(lambda) = exp(-sigma(lambda) * distance)
    //
    // Red is absorbed least, blue slightly more.
    // Values are intentionally subtle.
    // --------------------------------------------------------

    vec3 absorptionCoefficient = vec3(0.08, 0.035, 0.015) *
        uAbsorptionStrength;

    vec3 transmission = vec3(exp(-absorptionCoefficient.r *
        opticalLengthR), exp(-absorptionCoefficient.g *
        opticalLengthG), exp(-absorptionCoefficient.b *
        opticalLengthB));

    bool tirExitR;
    bool tirExitG;
    bool tirExitB;

    vec3 exitDirectionR = safeRefract(refractedR, exitNormalR, refractiveIndex.r, tirExitR);

    vec3 exitDirectionG = safeRefract(refractedG, exitNormalG, refractiveIndex.g, tirExitG);

    vec3 exitDirectionB = safeRefract(refractedB, exitNormalB, refractiveIndex.b, tirExitB);

    vec3 exitDirectionWorldR = normalize(vBasisX *
        exitDirectionR.x +
        vBasisY *
        exitDirectionR.y +
        vBasisZ *
        exitDirectionR.z);

    vec3 exitDirectionWorldG = normalize(vBasisX *
        exitDirectionG.x +
        vBasisY *
        exitDirectionG.y +
        vBasisZ *
        exitDirectionG.z);

    vec3 exitDirectionWorldB = normalize(vBasisX *
        exitDirectionB.x +
        vBasisY *
        exitDirectionB.y +
        vBasisZ *
        exitDirectionB.z);

    vec3 reflectedObject = reflect(rayDirectionObject, entryNormalObject);

    vec3 reflectedWorld = normalize(vBasisX *
        reflectedObject.x +
        vBasisY *
        reflectedObject.y +
        vBasisZ *
        reflectedObject.z);

    float diffuse = max(dot(N, L), 0.0);

    vec3 H = normalize(L + V);

    float specular = pow(max(dot(N, H), 0.0), 64.0);

    float cosTheta = max(dot(N, V), 0.0);

    float f0 = pow((uRefractiveIndex - 1.0) /
        (uRefractiveIndex + 1.0), 2.0);

    float fresnel = f0 +
        (1.0 - f0) *
        pow(1.0 - cosTheta, 5.0);

    vec3 transmittedEnvironment;

    if (uUseSceneColor != 0)
    {
        vec2 baseUV = gl_FragCoord.xy /
            uResolution;

        vec3 incidentWorld = normalize(vWorldPosition -
            uCameraPosition);

        vec3 incidentView = normalize(mat3(uView) *
            incidentWorld);

        vec3 exitViewR = normalize(mat3(uView) *
            exitDirectionWorldR);

        vec3 exitViewG = normalize(mat3(uView) *
            exitDirectionWorldG);

        vec3 exitViewB = normalize(mat3(uView) *
            exitDirectionWorldB);

        vec2 incidentSlope = directionSlope(incidentView);

        vec2 slopeR = directionSlope(exitViewR);

        vec2 slopeG = directionSlope(exitViewG);

        vec2 slopeB = directionSlope(exitViewB);

        float averagePath = (opticalLengthR +
            opticalLengthG +
            opticalLengthB) /
            3.0;

        float refractionScale = clamp(averagePath *
            0.030, 0.012, 0.085);

        vec2 offsetR = (slopeR -
            incidentSlope) *
            refractionScale;

        vec2 offsetG = (slopeG -
            incidentSlope) *
            refractionScale;

        vec2 offsetB = (slopeB -
            incidentSlope) *
            refractionScale;

        offsetR = clamp(offsetR, vec2(-0.12), vec2(0.12));

        offsetG = clamp(offsetG, vec2(-0.12), vec2(0.12));

        offsetB = clamp(offsetB, vec2(-0.12), vec2(0.12));

        vec2 uvR = clamp(baseUV + offsetR, vec2(0.002), vec2(0.998));

        vec2 uvG = clamp(baseUV + offsetG, vec2(0.002), vec2(0.998));

        vec2 uvB = clamp(baseUV + offsetB, vec2(0.002), vec2(0.998));

        vec3 sampleR = texture(uSceneColor, uvR).rgb;

        vec3 sampleG = texture(uSceneColor, uvG).rgb;

        vec3 sampleB = texture(uSceneColor, uvB).rgb;

        transmittedEnvironment = vec3(sampleR.r, sampleG.g, sampleB.b);
    }
    else
    {
        vec3 environmentR = sampleEnvironment(exitDirectionWorldR);

        vec3 environmentG = sampleEnvironment(exitDirectionWorldG);

        vec3 environmentB = sampleEnvironment(exitDirectionWorldB);

        transmittedEnvironment = vec3(environmentR.r, environmentG.g, environmentB.b);
    }

    vec3 transmittedColor = vec3(tirExitR ? 0.0 : transmittedEnvironment.r *
        transmission.r, tirExitG ? 0.0 : transmittedEnvironment.g *
        transmission.g, tirExitB ? 0.0 : transmittedEnvironment.b *
        transmission.b);

    vec3 reflectedColor;

    if (uUseSceneColor != 0)
    {
        reflectedColor = sampleHDRI(reflectedWorld);
    }
    else
    {
        reflectedColor = sampleEnvironment(reflectedWorld);
    }

// Keep reflections energetic, but no longer fake-neon.
    reflectedColor *= 0.85;

    vec3 color = transmittedColor *
        (1.0 - fresnel);

    color += reflectedColor *
        fresnel;

    vec3 specularEnvironment = uUseSceneColor != 0 ? sampleHDRI(reflect(normalize(vWorldPosition -
        uCameraPosition), N)) : vec3(1.0, 0.85, 0.65);

    color += specularEnvironment *
        specular *
        1.35;

    // ============================================================
// DEBUG MODES
//
// 0 = final
// 1 = normals
// 2 = optical path length
// 3 = chromatic separation
// 4 = TIR / invalid rays
// 5 = optical LOD
// 6 = instance IDs
// ============================================================

    if (uDebugMode == 1)
    {
        fragColor = vec4(N * 0.5 + 0.5, 1.0);

        return;
    }

    if (uDebugMode == 2)
    {
        float path = (opticalLengthR +
            opticalLengthG +
            opticalLengthB) / 3.0;

        path = clamp(path / 2.2, 0.0, 1.0);

    // Blue -> cyan -> yellow -> red.
        vec3 heat = vec3(smoothstep(0.45, 0.85, path), smoothstep(0.10, 0.55, path) *
            (1.0 -
            smoothstep(0.70, 1.0, path)), 1.0 -
            smoothstep(0.15, 0.60, path));

        fragColor = vec4(heat, 1.0);

        return;
    }

    if (uDebugMode == 3)
    {
        float rg = length(exitDirectionWorldR -
            exitDirectionWorldG);

        float gb = length(exitDirectionWorldG -
            exitDirectionWorldB);

        float rb = length(exitDirectionWorldR -
            exitDirectionWorldB);

    // Exaggerate the physically small differences.
        vec3 separation = vec3(rg, gb, rb) *
            80.0;

        fragColor = vec4(clamp(separation, 0.0, 1.0), 1.0);

        return;
    }

    if (uDebugMode == 4)
    {
        bool anyTIR = tirExitR ||
            tirExitG ||
            tirExitB;

        bool anyInvalid = !validExitR ||
            !validExitG ||
            !validExitB;

        vec3 diagnostic = vec3(0.02);

        if (anyTIR)
        {
            diagnostic = vec3(1.0, 0.0, 0.0);
        }

        if (anyInvalid)
        {
            diagnostic = vec3(1.0, 0.0, 1.0);
        }

        fragColor = vec4(diagnostic, 1.0);

        return;
    }

    if (uDebugMode == 5)
    {
    // Green = full optical shader.
    // Blue  = cheap optical LOD.

        vec3 lodColor = vOpticalLOD < 0.5 ? vec3(0.0, 1.0, 0.15) : vec3(0.0, 0.25, 1.0);

        fragColor = vec4(lodColor, 1.0);

        return;
    }

    if (uDebugMode == 6)
    {
    // Pseudo-random but deterministic color per instance.

        float id = float(vInstanceID);

        vec3 instanceColor = fract(sin(vec3(id * 12.9898, id * 78.233, id * 37.719)) *
            43758.5453);

        fragColor = vec4(instanceColor, 1.0);

        return;
    }

    fragColor = vec4(color, 1.0);
}

//#BLUR_FRAGMENT_SHADER

out vec4 fragColor;

uniform sampler2D uSource;
uniform vec2 uSourceResolution;
uniform vec2 uTargetResolution;
uniform vec2 uDirection;

uniform int uExtractBright;
vec3 source(vec2 uv){vec3 c=texture(uSource,uv).rgb;
    if(uExtractBright==0)return c;
    float brightness=max(c.r,max(c.g,c.b));
    float soft=clamp(brightness-.5,0.,1.);soft=soft*soft*.5;
    return c*max(brightness-1.,soft)/max(brightness,1e-5);
}
void main()
{
    vec2 uv = gl_FragCoord.xy / uTargetResolution;
    vec2 texel = 1.0 / uSourceResolution;

    float weights[5] = float[5](0.2270270270, 0.1945945946, 0.1216216216, 0.0540540541, 0.0162162162);

    vec3 result = source(uv) * weights[0];

    for (int i = 1; i < 5; i++)
    {
        vec2 offset = texel * uDirection * float(i) * 1.5;

        result += source(uv + offset) * weights[i];
        result += source(uv - offset) * weights[i];
    }

    fragColor = vec4(result, 1.0);
}

//#TEMPORAL_FRAGMENT_SHADER

out vec4 fragColor;
uniform sampler2D uCurrent;
uniform sampler2D uHistory;
uniform sampler2D uDepth;
uniform vec2 uResolution;
uniform int uHistoryValid;
uniform float uHistoryWeight;
uniform mat4 uInverseViewProjection;
uniform mat4 uPreviousViewProjection;

float temporalLuma(vec3 c){return dot(c,vec3(.2126,.7152,.0722));}

void main()
{
    vec2 uv=gl_FragCoord.xy/uResolution;
    vec2 px=1.0/uResolution;
    vec3 current=texture(uCurrent,uv).rgb;
    if(uHistoryValid==0){fragColor=vec4(current,1);return;}

    float depth=texture(uDepth,uv).r;
    vec4 world=uInverseViewProjection*vec4(uv*2.0-1.0,depth*2.0-1.0,1.0);
    world/=max(abs(world.w),1e-6);
    vec4 previousClip=uPreviousViewProjection*world;
    if(previousClip.w<=0.0){fragColor=vec4(current,1);return;}
    vec2 historyUV=previousClip.xy/previousClip.w*.5+.5;
    if(any(lessThan(historyUV,vec2(0)))||any(greaterThan(historyUV,vec2(1)))){
        fragColor=vec4(current,1);return;
    }

    vec3 n=texture(uCurrent,uv+vec2(0,px.y)).rgb;
    vec3 s=texture(uCurrent,uv-vec2(0,px.y)).rgb;
    vec3 e=texture(uCurrent,uv+vec2(px.x,0)).rgb;
    vec3 w=texture(uCurrent,uv-vec2(px.x,0)).rgb;
    vec3 lo=min(current,min(min(n,s),min(e,w)));
    vec3 hi=max(current,max(max(n,s),max(e,w)));
    // Clamp old radiance to what is present around this pixel now. This is the
    // inexpensive history rejection that prevents trails around the rotating prism.
    vec3 history=clamp(texture(uHistory,historyUV).rgb,lo,hi);
    float difference=abs(temporalLuma(history)-temporalLuma(current)) /
                     max(max(temporalLuma(history),temporalLuma(current)),.08);
    float reactive=smoothstep(.08,.70,difference);
    float weight=uHistoryWeight*(1.0-reactive);
    fragColor=vec4(mix(current,history,weight),1);
}

//#COMPOSITE_FRAGMENT_SHADER

out vec4 fragColor;

uniform sampler2D uScene;
uniform sampler2D uBloom;
uniform vec2 uResolution;
uniform float uBloomStrength;
uniform float uExposure;
uniform vec2 uSceneResolution;

vec3 sceneAA(vec2 uv)
{
    vec2 px=1.0/uSceneResolution;
    vec3 c=texture(uScene,uv).rgb;
    vec3 n=texture(uScene,uv+vec2(0,px.y)).rgb;
    vec3 s=texture(uScene,uv-vec2(0,px.y)).rgb;
    vec3 e=texture(uScene,uv+vec2(px.x,0)).rgb;
    vec3 w=texture(uScene,uv-vec2(px.x,0)).rgb;
    vec3 luma=vec3(.2126,.7152,.0722);
    float center=dot(c,luma),minimum=min(center,min(min(dot(n,luma),dot(s,luma)),min(dot(e,luma),dot(w,luma))));
    float maximum=max(center,max(max(dot(n,luma),dot(s,luma)),max(dot(e,luma),dot(w,luma))));
    float contrast=maximum-minimum;
    if(contrast<max(.025,maximum*.10))return c;
    vec2 direction=vec2(-(dot(n,luma)-dot(s,luma)),dot(e,luma)-dot(w,luma));
    direction=clamp(direction/max(abs(direction.x),abs(direction.y)+1e-6),vec2(-1),vec2(1))*px*.75;
    return (texture(uScene,uv-direction*.5).rgb+texture(uScene,uv+direction*.5).rgb)*.5;
}
uniform int uDebugMode;

void main()
{
    vec2 uv = gl_FragCoord.xy / uResolution;

    vec3 base = sceneAA(uv);
    vec3 bloom = texture(uBloom, uv).rgb;

    if (uDebugMode != 0)
    {
        // Debug buffers are already normalized display colors.
        // Do not HDR-tone-map them.

        fragColor = vec4(clamp(base, 0.0, 1.0), 1.0);

        return;
    }

    vec3 col = base +
        bloom *
        uBloomStrength;

    col=max(col*uExposure,0.0);
    // Map peak intensity with one scale factor, retaining spectral hue ratios.
    // Per-channel highlight clipping previously turned the caustic center white.
    float peak=max(col.r,max(col.g,col.b));
    float mapped=clamp((peak*(2.51*peak+.03))/(peak*(2.43*peak+.59)+.14),0.,1.);
    col*=mapped/max(peak,1e-6);

    col = pow(max(col, 0.0), vec3(1.0 / 2.2));

    fragColor = vec4(col, 1.0);
}

//#BACKGROUND_VERTEX_SHADER

layout (location = 0) in vec2 aPosition;

out vec2 vTexCoord;

void main()
{
    vTexCoord = aPosition * 0.5 + 0.5;

    gl_Position = vec4(aPosition, 0.0, 1.0);
}//#BACKGROUND_FRAGMENT_SHADER

in vec2 vTexCoord;

out vec4 fragColor;

uniform sampler2D uEnvironment;

uniform vec3 uCameraForward;
uniform vec3 uCameraRight;
uniform vec3 uCameraUp;

uniform float uTanHalfFov;
uniform float uAspect;
uniform float uEnvironmentRotation;

const float BACKGROUND_PI = 3.14159265358979323846;

vec2 backgroundDirectionToUV(
    vec3 direction
)
{
    vec3 d = normalize(direction);

    float longitude = atan(d.z, d.x);

    float latitude = asin(clamp(d.y, -1.0, 1.0));

    vec2 uv;

    uv.x = longitude /
        (2.0 *
        BACKGROUND_PI) +
        0.5 +
        uEnvironmentRotation;

    uv.y = 0.5 -
        latitude /
        BACKGROUND_PI;

    return uv;
}

void main()
{
    vec2 ndc = vTexCoord *
        2.0 -
        1.0;

    vec3 rayDirection = normalize(uCameraForward +
        uCameraRight *
        ndc.x *
        uAspect *
        uTanHalfFov +
        uCameraUp *
        ndc.y *
        uTanHalfFov);

    vec2 environmentUV = backgroundDirectionToUV(rayDirection);

    vec3 hdrColor = texture(uEnvironment, environmentUV).rgb;

    fragColor = vec4(hdrColor, 1.0);
}

//#BEAM_VERTEX_SHADER

layout (location = 0) in vec3 aPosition;
layout (location = 1) in vec3 aColor;
layout (location = 2) in float aIntensity;

uniform mat4 uView;
uniform mat4 uProjection;

out vec3 vColor;
out float vIntensity;

void main()
{
    vColor = aColor;

    vIntensity = aIntensity;

    gl_Position = uProjection *
        uView *
        vec4(aPosition, 1.0);
}

//#BEAM_FRAGMENT_SHADER

in vec3 vColor;
in float vIntensity;

out vec4 fragColor;

void main()
{
    vec3 color = vColor *
        vIntensity;

    fragColor = vec4(color, 0.42);
}
