using System;
using System.IO;
using System.IO.Compression;
using System.Text;

public sealed class ScenarioPngImage
{
    public int Width;
    public int Height;
    public byte[] Pixels;
}

public static class ScenarioPng
{
    private static readonly byte[] Signature = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
    private static readonly uint[] CrcTable = BuildCrcTable();
    private const int MaxImageBytes = 128 * 1024 * 1024;

    public static ScenarioPngImage Decode(byte[] png)
    {
        if (png == null || png.Length < 20) throw new InvalidDataException("png_too_short");
        for (int i = 0; i < Signature.Length; i++) if (png[i] != Signature[i]) throw new InvalidDataException("png_signature");
        int pos = 8;
        int width = 0, height = 0, bitDepth = 0, colorType = -1, interlace = 1;
        bool sawHeader = false;
        MemoryStream compressed = new MemoryStream();
        while (pos + 12 <= png.Length)
        {
            uint lengthValue = ReadU32(png, pos);
            if (lengthValue > MaxImageBytes) throw new InvalidDataException("png_chunk_too_large");
            int length = (int)lengthValue;
            if (pos + 12 + length > png.Length) throw new InvalidDataException("png_chunk_truncated");
            string type = Encoding.ASCII.GetString(png, pos + 4, 4);
            byte[] data = new byte[length];
            Buffer.BlockCopy(png, pos + 8, data, 0, length);
            uint expectedCrc = ReadU32(png, pos + 8 + length);
            if (ChunkCrc(png, pos + 4, length) != expectedCrc) throw new InvalidDataException("png_crc");
            if (type == "IHDR")
            {
                if (sawHeader || length != 13) throw new InvalidDataException("png_ihdr");
                width = checked((int)ReadU32(data, 0));
                height = checked((int)ReadU32(data, 4));
                bitDepth = data[8];
                colorType = data[9];
                if (data[10] != 0 || data[11] != 0 || data[12] != 0) throw new InvalidDataException("png_compression");
                interlace = data[12];
                if (width < 1 || height < 1 || width > 8192 || height > 8192) throw new InvalidDataException("png_dimensions");
                if (bitDepth != 8 || (colorType != 2 && colorType != 6)) throw new InvalidDataException("png_unsupported_format");
                sawHeader = true;
            }
            else if (type == "IDAT")
            {
                if (!sawHeader) throw new InvalidDataException("png_idat_before_ihdr");
                compressed.Write(data, 0, data.Length);
            }
            else if (type == "IEND")
            {
                break;
            }
            pos += 12 + length;
        }
        if (!sawHeader || compressed.Length < 6) throw new InvalidDataException("png_missing_data");
        int bpp = colorType == 6 ? 4 : 3;
        int rowBytes = checked(width * bpp);
        int expected = checked(height * (rowBytes + 1));
        if (expected > MaxImageBytes) throw new InvalidDataException("png_too_large");
        byte[] raw = Inflate(compressed.ToArray(), expected);
        byte[] pixels = new byte[checked(width * height * bpp)];
        byte[] previous = new byte[rowBytes];
        for (int y = 0; y < height; y++)
        {
            int input = y * (rowBytes + 1);
            int filter = raw[input];
            if (filter < 0 || filter > 4) throw new InvalidDataException("png_filter");
            byte[] current = new byte[rowBytes];
            for (int x = 0; x < rowBytes; x++)
            {
                int left = x >= bpp ? current[x - bpp] : 0;
                int up = previous[x];
                int upLeft = x >= bpp ? previous[x - bpp] : 0;
                int predictor;
                switch (filter)
                {
                    case 0: predictor = 0; break;
                    case 1: predictor = left; break;
                    case 2: predictor = up; break;
                    case 3: predictor = (left + up) / 2; break;
                    default:
                        int p = left + up - upLeft;
                        int pa = Math.Abs(p - left), pb = Math.Abs(p - up), pc = Math.Abs(p - upLeft);
                        predictor = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft);
                        break;
                }
                current[x] = unchecked((byte)(raw[input + 1 + x] + predictor));
            }
            Buffer.BlockCopy(current, 0, pixels, y * rowBytes, rowBytes);
            previous = current;
        }
        return new ScenarioPngImage { Width = width, Height = height, Pixels = pixels };
    }

    public static byte[] Crop(byte[] png, int x, int y, int width, int height)
    {
        ScenarioPngImage image = Decode(png);
        if (x < 0 || y < 0 || width < 1 || height < 1 || x + width > image.Width || y + height > image.Height)
            throw new InvalidDataException("png_crop_bounds");
        int bpp = image.Pixels.Length / (image.Width * image.Height);
        int outputRow = width * bpp;
        byte[] scanlines = new byte[checked(height * (outputRow + 1))];
        for (int row = 0; row < height; row++)
        {
            int destination = row * (outputRow + 1);
            scanlines[destination] = 0;
            Buffer.BlockCopy(image.Pixels, ((y + row) * image.Width + x) * bpp, scanlines, destination + 1, outputRow);
        }
        return Encode(width, height, bpp, scanlines);
    }

    private static byte[] Encode(int width, int height, int bpp, byte[] scanlines)
    {
        using (MemoryStream output = new MemoryStream())
        using (MemoryStream compressed = new MemoryStream())
        {
            output.Write(Signature, 0, Signature.Length);
            byte[] header = new byte[13];
            WriteU32(header, 0, (uint)width);
            WriteU32(header, 4, (uint)height);
            header[8] = 8;
            header[9] = bpp == 4 ? (byte)6 : (byte)2;
            WriteChunk(output, "IHDR", header);
            compressed.WriteByte(0x78);
            compressed.WriteByte(0x01);
            using (DeflateStream deflate = new DeflateStream(compressed, CompressionMode.Compress, true))
            {
                deflate.Write(scanlines, 0, scanlines.Length);
            }
            uint a = 1, b = 0;
            for (int i = 0; i < scanlines.Length; i++)
            {
                a = (a + scanlines[i]) % 65521;
                b = (b + a) % 65521;
            }
            uint adler = (b << 16) | a;
            compressed.WriteByte((byte)(adler >> 24));
            compressed.WriteByte((byte)(adler >> 16));
            compressed.WriteByte((byte)(adler >> 8));
            compressed.WriteByte((byte)adler);
            WriteChunk(output, "IDAT", compressed.ToArray());
            WriteChunk(output, "IEND", new byte[0]);
            return output.ToArray();
        }
    }

    private static byte[] Inflate(byte[] zlib, int expected)
    {
        if (zlib.Length < 6) throw new InvalidDataException("png_zlib_short");
        byte[] compressed = new byte[zlib.Length - 6];
        Buffer.BlockCopy(zlib, 2, compressed, 0, compressed.Length);
        using (MemoryStream input = new MemoryStream(compressed))
        using (DeflateStream deflate = new DeflateStream(input, CompressionMode.Decompress))
        using (MemoryStream output = new MemoryStream())
        {
            deflate.CopyTo(output);
            if (output.Length != expected) throw new InvalidDataException("png_scanline_length");
            return output.ToArray();
        }
    }

    private static void WriteChunk(Stream output, string type, byte[] data)
    {
        byte[] typeBytes = Encoding.ASCII.GetBytes(type);
        byte[] prefix = new byte[4];
        WriteU32(prefix, 0, (uint)data.Length);
        output.Write(prefix, 0, 4);
        output.Write(typeBytes, 0, 4);
        output.Write(data, 0, data.Length);
        byte[] crc = new byte[4];
        WriteU32(crc, 0, ChunkCrc(typeBytes, 0, data));
        output.Write(crc, 0, 4);
    }

    private static uint ChunkCrc(byte[] typeAndData, int dataStart, int dataLength)
    {
        uint crc = 0xffffffff;
        for (int i = dataStart; i < dataStart + 4; i++) crc = CrcTable[(crc ^ typeAndData[i]) & 0xff] ^ (crc >> 8);
        for (int i = dataStart + 4; i < dataStart + 4 + dataLength; i++) crc = CrcTable[(crc ^ typeAndData[i]) & 0xff] ^ (crc >> 8);
        return crc ^ 0xffffffff;
    }

    private static uint ChunkCrc(byte[] type, int typeStart, byte[] data)
    {
        uint crc = 0xffffffff;
        for (int i = typeStart; i < typeStart + 4; i++) crc = CrcTable[(crc ^ type[i]) & 0xff] ^ (crc >> 8);
        for (int i = 0; i < data.Length; i++) crc = CrcTable[(crc ^ data[i]) & 0xff] ^ (crc >> 8);
        return crc ^ 0xffffffff;
    }

    private static uint ReadU32(byte[] data, int offset)
    {
        return ((uint)data[offset] << 24) | ((uint)data[offset + 1] << 16) | ((uint)data[offset + 2] << 8) | data[offset + 3];
    }

    private static void WriteU32(byte[] data, int offset, uint value)
    {
        data[offset] = (byte)(value >> 24);
        data[offset + 1] = (byte)(value >> 16);
        data[offset + 2] = (byte)(value >> 8);
        data[offset + 3] = (byte)value;
    }

    private static uint[] BuildCrcTable()
    {
        uint[] table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }
}
