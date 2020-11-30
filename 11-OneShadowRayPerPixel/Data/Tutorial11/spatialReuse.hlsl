/* Spatial Reuse */

// Include helper functions
// #include "diffusePlus1ShadowUtils.hlsli"
#include "pbr.hlsli"
#include "randomHelper.hlsli"

static const float PI = 3.14159265f;

// G-Buffer
RWTexture2D<float4> gWsPos;
RWTexture2D<float4> gWsNorm;
RWTexture2D<float4> gMatDif;
RWTexture2D<float4> gMatSpec;
RWTexture2D<float4> gMatExtra;
RWTexture2D<float4> gMatEmissive;

// Reservoir texture
RWTexture2D<float4> emittedLight; // xyz: light color
RWTexture2D<float4> toSample; // xyz: hit to sample // w: distToLight
RWTexture2D<float4> sampleNormalArea; // xyz: sample noraml // w: area of light
RWTexture2D<float4> reservoir; // x: W // y: Wsum // zw: not used
RWTexture2D<int> M;

cbuffer RISCB
{
	uint gFrameCount; // Frame counter, used to perturb random seed each frame
};

struct Pingpong
{
	float4 preservoir        : SV_Target0;
	float4 ptoSample         : SV_Target1;
	float4 psampleNormalArea : SV_Target2;
	float4 pemittedLight     : SV_Target3;
	int    pM                : SV_Target4;
};

void updatereservoir(float3 le, float4 tos, float4 sna, float w, inout uint seed, inout Pingpong pp) {
	pp.preservoir.y += w;  // wsum += w
	pp.pM = pp.pM + 1;
	if (pp.preservoir.y > 0 && nextRand(seed) < (w / pp.preservoir.y)) {
		pp.pemittedLight = float4(le, 1.f);
		pp.ptoSample = tos;
		pp.psampleNormalArea = sna;
	}
	return;
}

Pingpong main(float2 texC : TEXCOORD, float4 pos : SV_Position)
{
	uint2 pixelPos = (uint2)pos.xy; // Where is this pixel on screen?
	float width;
	float height;
	reservoir.GetDimensions(width, height);

	float M_sum = 0.0;
	uint seed = initRand(pixelPos.x + pixelPos.y * width.x, gFrameCount, 16);
	Pingpong pp;

	pp.preservoir = reservoir[pixelPos];
	pp.ptoSample = toSample[pixelPos];
	pp.psampleNormalArea = sampleNormalArea[pixelPos];
	pp.pemittedLight = emittedLight[pixelPos];
	pp.pM = M[pixelPos];

	int i_total = 0;
	// Sample k = 5 (k = 3 for our unbiased algorithm) random points in a 30 - pixel radius around the current pixel
	for (int i = 0; i < 5; i++) {
		if (i_total > 10) {
			break;
		}	  
		float r = 30.0 * sqrt(nextRand(seed));
		float theta = 2.0 * PI * nextRand(seed);
		uint2 neighborPos;
		neighborPos.x = pixelPos.x + clamp(int(r * cos(theta)), 0, int(width - 1));
		neighborPos.y = pixelPos.y + clamp(int(r * sin(theta)), 0, int(height - 1));
		// The angle between normals of the current pixel to the neighboring pixel exceeds 25 degree
		if ( dot( normalize(gWsNorm[pixelPos].xyz), normalize(gWsNorm[neighborPos].xyz) ) < 0.9063) {
			i--;
			i_total++;
			continue;
		}
		// Exceed 10% of current pixel's depth
		if (gWsNorm[neighborPos].w > 1.1 * gWsNorm[pixelPos].w || gWsNorm[neighborPos].w < 0.9 * gWsNorm[pixelPos].w) {
			i--;
			i_total++;
			continue;
		}
		float3 nor = normalize(gWsNorm[neighborPos].xyz);
		float p_hat = evalP(toSample[neighborPos].xyz, gMatDif[neighborPos].xyz, emittedLight[neighborPos].xyz, nor);
		float3 Le = emittedLight[neighborPos].xyz;
		float4 toS = toSample[neighborPos];
		float4 sNA = sampleNormalArea[neighborPos];
		float w = p_hat * reservoir[neighborPos].x * M[neighborPos];
		updatereservoir(Le, toS, sNA, w, seed, pp);
		M_sum += M[neighborPos];
	}

	pp.pM = M_sum;
	float3 nor_s = normalize(gWsNorm[pixelPos].xyz);
	float p_hat_s = evalP(pp.ptoSample.xyz, gMatDif[pixelPos].xyz, pp.pemittedLight.xyz, nor_s);
	pp.preservoir.x = pp.preservoir.y / p_hat_s / float(pp.pM);

	return pp;
}
