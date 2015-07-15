/*
Copyright (c) 2014-2015 Timur Gafarov 

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dlib.image.io.tga;

private
{
    import std.stdio;
    import std.file;
    import std.conv;

    import dlib.core.memory;
    import dlib.core.stream;
    import dlib.core.compound;
    import dlib.image.color;
    import dlib.image.image;
    import dlib.image.io.io;
    import dlib.image.io.utils;
    import dlib.filesystem.local;
}

// uncomment this to see debug messages:
//version = TGADebug;

struct TGAHeader
{
    ubyte idLength;
    ubyte type;
    ubyte encoding;
    short colmapStart;
    short colmapLen;
    ubyte colmapBits;
    short xstart;
    short ystart;
    short width;
    short height;
    ubyte bpp;
    ubyte descriptor;
}

class TGALoadException: ImageLoadException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

/*
 * Load PNG from file using local FileSystem.
 * Causes GC allocation
 */
SuperImage loadTGA(string filename)
{
    InputStream input = openForInput(filename);
    
    try
    {
        return loadTGA(input);
    }
    catch (TGALoadException ex)
    {
        throw new Exception("'" ~ filename ~ "' :" ~ ex.msg, ex.file, ex.line, ex.next);
    }
    finally
    {
        input.close();
    }
}

/*
 * Load TGA from stream using default image factory.
 * Causes GC allocation
 */
SuperImage loadTGA(InputStream istrm)
{
    Compound!(SuperImage, string) res = 
        loadTGA(istrm, defaultImageFactory);
    if (res[0] is null)
        throw new TGALoadException(res[1]);
    else
        return res[0];
}

/*
 * Load TGA from stream using specified image factory.
 * GC-free
 */
Compound!(SuperImage, string) loadTGA(
    InputStream istrm, 
    SuperImageFactory imgFac)
{
    SuperImage img = null;

    Compound!(SuperImage, string) error(string errorMsg)
    {
        if (img)
        {
            img.free();
            img = null;
        }
        return compound(img, errorMsg);
    }

    TGAHeader readHeader()
    {
        TGAHeader hdr = readStruct!TGAHeader(istrm);
        version(TGADebug)
        {
            writefln("idLength = %s", hdr.idLength);
            writefln("type = %s", hdr.type);
           /*
            * Encoding flag: 
            * 1 = Raw indexed image
            * 2 = Raw RGB
            * 3 = Raw greyscale
            * 9 = RLE indexed            * 10 = RLE RGB
            * 11 = RLE greyscale
            * 32 & 33 = Other compression, indexed
            */
            writefln("encoding = %s", hdr.encoding);

            writefln("colmapStart = %s", hdr.colmapStart);
            writefln("colmapLen = %s", hdr.colmapLen);
            writefln("colmapBits = %s", hdr.colmapBits);
            writefln("xstart = %s", hdr.xstart);
            writefln("ystart = %s", hdr.ystart);       
            writefln("width = %s", hdr.width);
            writefln("height = %s", hdr.height);
            writefln("bpp = %s", hdr.bpp);
            writefln("descriptor = %s", hdr.descriptor);
            writeln("-------------------"); 
        }   
        return hdr;
    }

    SuperImage readRawRGB(ref TGAHeader hdr)
    {
        uint channels = hdr.bpp / 8;
        SuperImage res = imgFac.createImage(hdr.width, hdr.height, channels, 8); 
        istrm.fillArray(res.data);
        return res;
    }

    SuperImage readRLERGB(ref TGAHeader hdr)
    {
        uint channels = hdr.bpp / 8;
        uint imageSize = hdr.width * hdr.height * channels;
        SuperImage res = imgFac.createImage(hdr.width, hdr.height, channels, 8); 

        // Calculate offset to image data
        uint dataOffset = 18 + hdr.idLength;

        // Add palette offset for indexed images
        if (hdr.type == 1)
            dataOffset += 768; 

        // Read compressed data
        // TODO: take scanline order into account (bottom-up or top-down)
        ubyte[] data = New!(ubyte[])(cast(uint)istrm.size - dataOffset); 
        istrm.fillArray(data);

        uint ii = 0;
        uint i = 0;
        while (ii < imageSize)
        {
            ubyte b = data[i];
            i++;

            if (b & 0x80) // Run length chunk
            {
                // Get run length
                uint runLength = b - 127;

                // Repeat the next pixel runLength times
                for (uint j = 0; j < runLength; j++)
                {
                    foreach(pIndex; 0..channels)
                        res.data[ii + pIndex] = data[i + pIndex];

                    ii += channels;
                }

                i += channels;
            }
            else // Raw chunk
            {
                // Get run length
                uint runLength = b + 1;

                // Write the next runLength pixels directly
                for (uint j = 0; j < runLength; j++)
                {
                    foreach(pIndex; 0..channels)
                        res.data[ii + pIndex] = data[i + pIndex];

                    ii += channels;
                    i += channels;
                }
            }
        }

        Delete(data);

        return res;
    }

    auto hdr = readHeader();

    if (hdr.idLength)
    {
        char[] id = New!(char[])(hdr.idLength);
        istrm.fillArray(id);

        version(TGADebug)
        {
            writefln("id = %s", id);
        }

        Delete(id);
    }

    if (hdr.encoding != 2 && hdr.encoding != 10)
        return error("loadTGA error: only RGB images are supported");

    if (hdr.encoding == 2)
    {
        img = readRawRGB(hdr);
    }
    else if (hdr.encoding == 10)
    {
        img = readRLERGB(hdr);
    }

    img.swapRGB();

    return compound(img, "");
}

void swapRGB(SuperImage img)
{
    foreach(x; 0..img.width)
    foreach(y; 0..img.height)
    {
        img[x, y] = Color4f(img[x, y].bgr);
    }
}

