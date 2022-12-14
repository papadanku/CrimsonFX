
#if !defined(CVIDEOPROCESSING_FXH)
    #define CVIDEOPROCESSING_FXH

    #include "cMacros.fxh"
    #include "cGraphics.fxh"

    // Lucas-Kanade optical flow with bilinear fetches

    /*
        Calculate Lucas-Kanade optical flow by solving (A^-1 * B)
        ---------------------------------------------------------
        [A11 A12]^-1 [-B1] -> [ A11 -A12] [-B1]
        [A21 A22]^-1 [-B2] -> [-A21  A22] [-B2]
        ---------------------------------------------------------
        [ Ix^2 -IxIy] [-IxIt]
        [-IxIy  Iy^2] [-IyIt]
    */

    struct Texel
    {
        float2 MainTex;
        float2 Size;
        float2 LOD;
    };

    struct UnpackedTex
    {
        float4 Tex;
        float4 WarpedTex;
    };

    void UnpackTex(in Texel Tex, in float4 Column, in float2 Vectors, out UnpackedTex Output[3])
    {
        // Calculate column tex
        float4 ColumnTex = Tex.MainTex.xyyy + (Column * abs(Tex.Size.xyyy));

        // Calculate texture attributes of each packed column of tex
        float4 WarpPackedTex = 0.0;
        // Warp horizontal texture coordinates with horizontal motion vector
        WarpPackedTex.x = ColumnTex.x + (Vectors.x * abs(Tex.Size.x));
        // Warp vertical texture coordinates with vertical motion vector
        WarpPackedTex.yzw = ColumnTex.yzw + (Vectors.yyy * abs(Tex.Size.yyy));

        // Unpack and assemble the column's texture coordinates
        // Outputs float4(ColumnTex, 0.0, LOD) in 1 MAD
        const float4 TexMask = float4(1.0, 1.0, 0.0, 0.0);
        Output[0].Tex = (ColumnTex.xyyy * TexMask) + Tex.LOD.xxxy;
        Output[1].Tex = (ColumnTex.xzzz * TexMask) + Tex.LOD.xxxy;
        Output[2].Tex = (ColumnTex.xwww * TexMask) + Tex.LOD.xxxy;

        Output[0].WarpedTex = (WarpPackedTex.xyyy * TexMask) + Tex.LOD.xxxy;
        Output[1].WarpedTex = (WarpPackedTex.xzzz * TexMask) + Tex.LOD.xxxy;
        Output[2].WarpedTex = (WarpPackedTex.xwww * TexMask) + Tex.LOD.xxxy;
    }

    // [-1.0, 1.0] -> [DestSize.x, DestSize.y]
    float2 DecodeVectors(float2 Vectors, float2 ImageSize)
    {
        return Vectors / abs(ImageSize);
    }

    // [DestSize.x, DestSize.y] -> [-1.0, 1.0]
    float2 EncodeVectors(float2 Vectors, float2 ImageSize)
    {
        return clamp(Vectors * abs(ImageSize), -1.0, 1.0);
    }

    float2 GetPixelPyLK
    (
        float2 MainTex,
        float2 Vectors,
        sampler2D SampleI0_G,
        sampler2D SampleI0,
        sampler2D SampleI1,
        bool CoarseLevel
    )
    {
        // Setup constants
        const int WindowSize = 9;
        const float E = 1.0;

        // Initialize variables
        float3 A = 0.0;
        float2 B = 0.0;
        float2 R = 0.0;
        float2 IT[WindowSize];
        bool2 Refine = true;
        float Determinant = 0.0;
        float2 MVectors = 0.0;

        // Calculate main texel information (TexelSize, TexelLOD)
        Texel Tex;
        Tex.MainTex = MainTex;
        float2 Ix = ddx(Tex.MainTex);
        float2 Iy = ddy(Tex.MainTex);
        float DPX = dot(Ix, Ix);
        float DPY = dot(Iy, Iy);
        Tex.Size.x = Ix.x;
        Tex.Size.y = Iy.y;
        // log2(x^n) = n*log2(x)
        Tex.LOD = float2(0.0, 0.5) * log2(max(DPX, DPY));

        // Decode written vectors from coarser level
        Vectors = DecodeVectors(Vectors, Tex.Size);

        // The spatial(S) and temporal(T) derivative neighbors to sample
        UnpackedTex TexA[3];
        UnpackTex(Tex, float4(-1.0, 1.0, 0.0, -1.0), Vectors, TexA);

        UnpackedTex TexB[3];
        UnpackTex(Tex, float4(0.0, 1.0, 0.0, -1.0), Vectors, TexB);

        UnpackedTex TexC[3];
        UnpackTex(Tex, float4(1.0, 1.0, 0.0, -1.0), Vectors, TexC);

        UnpackedTex Pixel[WindowSize] =
        {
            TexA[0], TexA[1], TexA[2],
            TexB[0], TexB[1], TexB[2],
            TexC[0], TexC[1], TexC[2],
        };

        // Calculate sum of squared differences
        for(int i = 0; i < WindowSize; i++)
        {
            float2 I0 = tex2Dlod(SampleI0, Pixel[i].Tex).rg;
            float2 I1 = tex2Dlod(SampleI1, Pixel[i].WarpedTex).rg;
            IT[i] = I0 - I1;
            R += (abs(IT[i]) * abs(IT[i]));
        }

        // Calculate red channel of optical flow

        if((CoarseLevel == false) && (R.r < E))
        {
            Refine.r = false;
        }

        [branch]
        if(Refine.r)
        {
            [unroll]
            for(int i = 0; i < WindowSize; i++)
            {
                float2 G = tex2Dlod(SampleI0_G, Pixel[i].Tex).xz;
                // A.x = A11; A.y = A22; A.z = A12/A22
                A.xyz += (G.xyx * G.xyy);
                // B.x = B1; B.y = B2
                B.xy += (G.xy * IT[i].rr);
            }
        }

        // Calculate green channel of optical flow

        if((CoarseLevel == false) && (R.g < E))
        {
            Refine.g = false;
        }

        [branch]
        if(Refine.g)
        {
            [unroll]
            for(int i = 0; i < WindowSize; i++)
            {
                float2 G = tex2Dlod(SampleI0_G, Pixel[i].Tex).yw;
                // A.x = A11; A.y = A22; A.z = A12/A22
                A.xyz += (G.xyx * G.xyy);
                // B.x = B1; B.y = B2
                B.xy += (G.xy * IT[i].gg);
            }
        }

        // Create -IxIy (A12) for A^-1 and its determinant
        A.z = -A.z;

        // Make determinant non-zero
        A.xy = A.xy + FP16_SMALLEST_SUBNORMAL;

        // Calculate A^-1 determinant
        Determinant = ((A.x * A.y) - (A.z * A.z));

        // Solve A^-1
        A = A / Determinant;

        // Calculate Lucas-Kanade matrix
        MVectors = mul(-B.xy, float2x2(A.yzzx));
        MVectors = (Determinant != 0.0) ? MVectors : 0.0;

        // Propagate and encode vectors
        MVectors = EncodeVectors(Vectors + MVectors, Tex.Size);
        return MVectors;
    }
#endif
