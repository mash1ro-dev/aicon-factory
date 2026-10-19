// Windows PowerShell 5.1 / .NET Framework 4.x compatible.
// All image work is in memory. The original file is opened read-only and never modified.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace Aicon
{
    public sealed class SessionItem : System.ComponentModel.INotifyPropertyChanged
    {
        public event System.ComponentModel.PropertyChangedEventHandler PropertyChanged;
        private void Changed(string name) { var handler = PropertyChanged; if (handler != null) handler(this, new System.ComponentModel.PropertyChangedEventArgs(name)); }
        public string Id { get; set; }
        public string Source { get; set; }
        public string FileName { get; set; }
        public string Name { get; set; }
        public ImageResult Result { get; set; }
        public string SizeKey { get; set; }
        public string SavedPath { get; set; }
        public string Error { get; set; }
        private int number; public int Number { get { return number; } set { number=value; Changed("DisplayName"); } }
        public string DisplayName { get { return Number+". "+FileName; } }
        private string status; public string Status { get { return status; } set { status=value; Changed("Status"); } }
        private bool saveChecked; public bool SaveChecked { get { return saveChecked; } set { saveChecked=value; Changed("SaveChecked"); } }
        private bool isCurrent; public bool IsCurrent { get { return isCurrent; } set { isCurrent=value; Changed("IsCurrent"); } }
        private object thumbnail; public object Thumbnail { get { return thumbnail; } set { thumbnail=value; Changed("Thumbnail"); } }
    }
    public sealed class ImageResult
    {
        public byte[] Ico { get; internal set; }
        public byte[] Preview { get; internal set; }
        public Dictionary<int, byte[]> Frames { get; internal set; }
        public Dictionary<int, List<GeometryTrace>> Geometry { get; internal set; }
        public int SourceWidth { get; internal set; }
        public int SourceHeight { get; internal set; }
        public int TrimmedWidth { get; internal set; }
        public int TrimmedHeight { get; internal set; }
    }

    // Per-result diagnostic evidence of the actual GDI+ affine matrices used.
    public sealed class GeometryTrace
    {
        public string Stage;
        public float ScaleX, ScaleY, ShearX, ShearY;
        public float SourceWidth, SourceHeight, DestinationX, DestinationY, DestinationWidth, DestinationHeight;
        public int CanvasWidth, CanvasHeight;
    }
    public static class ImageEngine
    {
        public const int MaximumFileBytes = 64 * 1024 * 1024;
        public const int MaximumDimension = 16384;
        public const long MaximumPixels = 24000000;
        public const double PaddingFraction = 0.08;
        private static readonly int[] IconSizes = new int[] { 16, 24, 32, 48, 64, 128, 256 };
        private static readonly uint[] CrcTable = MakeCrcTable();
        private static string decoderPath;
        private const int DecoderTimeoutMilliseconds = 30000;

        // Call once with the bundled App\Native\dwebp.exe absolute path.
        // Do not use PATH lookup, a system codec, or a runtime download as a fallback.
        public static void ConfigureWebPDecoder(string absolutePath)
        {
            if (String.IsNullOrWhiteSpace(absolutePath) || !Path.IsPathRooted(absolutePath))
                throw new ArgumentException("WebP decoder path must be an absolute path.", "absolutePath");
            string fullPath = Path.GetFullPath(absolutePath);
            if (!File.Exists(fullPath))
                throw new FileNotFoundException("The bundled WebP decoder is missing. Reinstall AICON FACTORY.", fullPath);
            decoderPath = fullPath;
        }

        // Header/CRC validation only. Call before any UI decoder opens a selected file.
        public static void ValidateSource(string source)
        {
            ImageHeader header;
            ReadValidatedSource(source, out header);
        }

        private static byte[] ReadValidatedSource(string source, out ImageHeader header)
        {
            if (String.IsNullOrWhiteSpace(source))
                throw new ArgumentException("Choose an image file.", "source");
            string path = Path.GetFullPath(source);
            string extension = Path.GetExtension(path).ToLowerInvariant();
            if (extension != ".png" && extension != ".jpg" && extension != ".jpeg" && extension != ".webp")
                throw new InvalidDataException("Use a PNG, JPG, JPEG, or WEBP image.");

            byte[] input = ReadSource(path);
            header = Inspect(input);
            bool extensionMatches = (header.Kind == ImageKind.Png && extension == ".png") ||
                (header.Kind == ImageKind.Jpeg && (extension == ".jpg" || extension == ".jpeg")) ||
                (header.Kind == ImageKind.WebP && extension == ".webp");
            if (!extensionMatches)
                throw new InvalidDataException("The image content does not match its file extension.");

            return input;
        }

        public static ImageResult Process(string source)
        {
            return Process(source, IconSizes);
        }

        public static ImageResult Process(string source, int[] requestedSizes)
        {
            if (requestedSizes == null || requestedSizes.Length == 0) throw new ArgumentException("Choose at least one icon size.");
            SortedSet<int> sizes = new SortedSet<int>(requestedSizes);
            foreach (int size in sizes) if (Array.IndexOf(IconSizes, size) < 0) throw new ArgumentException("Unsupported icon size.");
            ImageHeader header;
            byte[] input = ReadValidatedSource(source, out header);

            using (Bitmap original = header.Kind == ImageKind.WebP ? DecodeWebP(input, header) : DecodeGdi(input, header))
            {
                Rectangle bounds = FindVisibleBounds(original);
                ImageResult result = new ImageResult();
                result.SourceWidth = original.Width;
                result.SourceHeight = original.Height;
                result.TrimmedWidth = bounds.Width;
                result.TrimmedHeight = bounds.Height;
                result.Frames = new Dictionary<int, byte[]>();

                result.Geometry = new Dictionary<int, List<GeometryTrace>>();
                // Intermediate bitmap allocation may ceil dimensions, but its active
                // RectangleF and the same affine scale on both axes remain intact.
                using (UniformRaster master = BuildUniformMaster(original,
                    new RectangleF(bounds.X, bounds.Y, bounds.Width, bounds.Height)))
                {
                    foreach (int size in sizes)
                    {
                        List<GeometryTrace> geometry = new List<GeometryTrace>(master.Trace);
                        using (UniformRaster frame = RenderUniformFrame(master, size, geometry))
                            result.Frames.Add(size, EncodePng(frame.Bitmap));
                        result.Geometry.Add(size, geometry);
                    }
                }

                result.Preview = result.Frames[sizes.Max];
                result.Ico = BuildIcon(result.Frames);
                return result;
            }
        }

        private static byte[] ReadSource(string path)
        {
            // FileShare.Read prevents concurrent writers while taking this read-only snapshot.
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length == 0 || stream.Length > MaximumFileBytes)
                    throw new InvalidDataException("The image must be nonempty and no larger than 64 MiB.");
                byte[] bytes = new byte[(int)stream.Length];
                ReadExactly(stream, bytes, 0, bytes.Length);
                return bytes;
            }
        }

        private enum ImageKind { Png, Jpeg, WebP }
        private sealed class ImageHeader
        {
            public ImageKind Kind;
            public int Width;
            public int Height;
            public ImageHeader(ImageKind kind, int width, int height)
            {
                CheckDimensions(width, height);
                Kind = kind;
                Width = width;
                Height = height;
            }
        }

        private static ImageHeader Inspect(byte[] data)
        {
            if (data.Length >= 8 && data[0] == 137 && FourCC(data, 1, "PNG\r") &&
                data[5] == 10 && data[6] == 26 && data[7] == 10)
                return InspectPng(data);
            if (data.Length >= 4 && data[0] == 255 && data[1] == 216)
                return InspectJpeg(data);
            if (data.Length >= 20 && FourCC(data, 0, "RIFF") && FourCC(data, 8, "WEBP"))
                return InspectWebP(data);
            throw new InvalidDataException("The file is not a supported image, or its header is damaged.");
        }

        private static void CheckDimensions(int width, int height)
        {
            if (width < 1 || height < 1 || width > MaximumDimension || height > MaximumDimension ||
                (long)width * height > MaximumPixels)
                throw new InvalidDataException("Image dimensions exceed the safety limit (16,384 pixels per side, 24 million pixels total).");
        }

        private static ImageHeader InspectPng(byte[] data)
        {
            int position = 8;
            ImageHeader header = null;
            bool sawData = false;
            bool sawEnd = false;
            while (position < data.Length)
            {
                if (data.Length - position < 12) throw Damaged("PNG");
                uint length = ReadU32BE(data, position);
                if (length > Int32.MaxValue || (long)position + 12 + length > data.Length) throw Damaged("PNG");
                int count = (int)length;
                if (position == 8)
                {
                    if (count != 13 || !FourCC(data, position + 4, "IHDR")) throw Damaged("PNG");
                    uint width = ReadU32BE(data, position + 8);
                    uint height = ReadU32BE(data, position + 12);
                    if (width > Int32.MaxValue || height > Int32.MaxValue) throw Damaged("PNG");
                    header = new ImageHeader(ImageKind.Png, (int)width, (int)height);
                }
                else if (FourCC(data, position + 4, "IHDR")) throw Damaged("PNG");
                if (FourCC(data, position + 4, "acTL"))
                    throw new InvalidDataException("Animated PNG is not supported. Export a still PNG first.");
                if (FourCC(data, position + 4, "IDAT")) sawData = true;
                uint expectedCrc = ReadU32BE(data, position + 8 + count);
                if (PngCrc(data, position + 4, count + 4) != expectedCrc) throw Damaged("PNG");
                position += count + 12;
                if (FourCC(data, position - count - 8, "IEND"))
                {
                    if (count != 0 || position != data.Length) throw Damaged("PNG");
                    sawEnd = true;
                    break;
                }
            }
            if (header == null || !sawData || !sawEnd) throw Damaged("PNG");
            return header;
        }

        private static ImageHeader InspectJpeg(byte[] data)
        {
            // Validate metadata dimensions before GDI+ is allowed to allocate decoded pixels.
            int position = 2;
            ImageHeader header = null;
            bool sawScan = false;
            if (data[data.Length - 2] != 255 || data[data.Length - 1] != 217) throw Damaged("JPEG");
            while (position < data.Length - 1)
            {
                if (data[position++] != 255) throw Damaged("JPEG");
                while (position < data.Length && data[position] == 255) position++;
                if (position >= data.Length) throw Damaged("JPEG");
                byte marker = data[position++];
                if (marker == 0 || marker == 216 || marker == 217) throw Damaged("JPEG");
                if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
                if (position + 2 > data.Length) throw Damaged("JPEG");
                int length = (data[position] << 8) | data[position + 1];
                if (length < 2 || position + length > data.Length) throw Damaged("JPEG");
                if (marker >= 192 && marker <= 207 && marker != 196 && marker != 200 && marker != 204)
                {
                    if (length < 8 || header != null) throw Damaged("JPEG");
                    int height = (data[position + 3] << 8) | data[position + 4];
                    int width = (data[position + 5] << 8) | data[position + 6];
                    header = new ImageHeader(ImageKind.Jpeg, width, height);
                }
                if (marker == 218) { sawScan = true; break; }
                position += length;
            }
            if (header == null || !sawScan) throw Damaged("JPEG");
            return header;
        }

        private static ImageHeader InspectWebP(byte[] data)
        {
            if ((long)ReadU32LE(data, 4) + 8 != data.Length) throw Damaged("WebP");
            ImageHeader canvas = null;
            ImageHeader image = null;
            int position = 12;
            bool sawExtended = false;
            while (position < data.Length)
            {
                if (data.Length - position < 8) throw Damaged("WebP");
                uint rawLength = ReadU32LE(data, position + 4);
                if (rawLength > Int32.MaxValue || (long)position + 8 + rawLength + (rawLength & 1) > data.Length)
                    throw Damaged("WebP");
                int length = (int)rawLength;
                int payload = position + 8;
                if (FourCC(data, position, "VP8X"))
                {
                    if (position != 12 || length != 10 || sawExtended) throw Damaged("WebP");
                    if ((data[payload] & 2) != 0)
                        throw new InvalidDataException("Animated WebP is not supported. Export a still WebP or PNG first.");
                    canvas = new ImageHeader(ImageKind.WebP, ReadU24LE(data, payload + 4) + 1, ReadU24LE(data, payload + 7) + 1);
                    sawExtended = true;
                }
                else if (FourCC(data, position, "ANIM") || FourCC(data, position, "ANMF"))
                    throw new InvalidDataException("Animated WebP is not supported. Export a still WebP or PNG first.");
                else if (FourCC(data, position, "VP8 "))
                {
                    if (image != null || length < 10 || (data[payload] & 1) != 0 ||
                        data[payload + 3] != 157 || data[payload + 4] != 1 || data[payload + 5] != 42)
                        throw Damaged("WebP");
                    image = new ImageHeader(ImageKind.WebP,
                        (data[payload + 6] | (data[payload + 7] << 8)) & 16383,
                        (data[payload + 8] | (data[payload + 9] << 8)) & 16383);
                }
                else if (FourCC(data, position, "VP8L"))
                {
                    if (image != null || length < 5 || data[payload] != 47) throw Damaged("WebP");
                    uint bits = ReadU32LE(data, payload + 1);
                    if ((bits >> 29) != 0) throw Damaged("WebP");
                    image = new ImageHeader(ImageKind.WebP, (int)(bits & 16383) + 1, (int)((bits >> 14) & 16383) + 1);
                }
                if ((length & 1) != 0 && data[payload + length] != 0) throw Damaged("WebP");
                position = payload + length + (length & 1);
            }
            if (image == null || (canvas != null && (image.Width != canvas.Width || image.Height != canvas.Height)))
                throw Damaged("WebP");
            return image;
        }

        private static Bitmap DecodeGdi(byte[] data, ImageHeader header)
        {
            try
            {
                using (MemoryStream stream = new MemoryStream(data, false))
                using (Image image = Image.FromStream(stream, true, true))
                {
                    CheckDimensions(image.Width, image.Height);
                    if (image.Width != header.Width || image.Height != header.Height) throw Damaged("image");
                    ApplyOrientation(image);
                    Bitmap bitmap = new Bitmap(image.Width, image.Height, PixelFormat.Format32bppArgb);
                    try
                    {
                        using (Graphics graphics = Graphics.FromImage(bitmap))
                        {
                            graphics.CompositingMode = CompositingMode.SourceCopy;
                            graphics.DrawImage(image, new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                                0, 0, image.Width, image.Height, GraphicsUnit.Pixel);
                        }
                        return bitmap;
                    }
                    catch { bitmap.Dispose(); throw; }
                }
            }
            catch (ArgumentException ex) { throw new InvalidDataException("The image could not be decoded. It may be damaged or unsupported.", ex); }
            catch (ExternalException ex) { throw new InvalidDataException("The image could not be decoded. It may be damaged or unsupported.", ex); }
            catch (OutOfMemoryException ex) { throw new InvalidDataException("The image could not be decoded, or there is not enough memory.", ex); }
        }

        private static void ApplyOrientation(Image image)
        {
            const int orientationId = 0x112;
            if (Array.IndexOf(image.PropertyIdList, orientationId) < 0) return;
            PropertyItem item = image.GetPropertyItem(orientationId);
            if (item.Value == null || item.Value.Length < 2) return;
            int orientation = item.Value[0] | (item.Value[1] << 8);
            RotateFlipType flip = RotateFlipType.RotateNoneFlipNone;
            switch (orientation)
            {
                case 2: flip = RotateFlipType.RotateNoneFlipX; break;
                case 3: flip = RotateFlipType.Rotate180FlipNone; break;
                case 4: flip = RotateFlipType.Rotate180FlipX; break;
                case 5: flip = RotateFlipType.Rotate90FlipX; break;
                case 6: flip = RotateFlipType.Rotate90FlipNone; break;
                case 7: flip = RotateFlipType.Rotate270FlipX; break;
                case 8: flip = RotateFlipType.Rotate270FlipNone; break;
            }
            if (flip != RotateFlipType.RotateNoneFlipNone) image.RotateFlip(flip);
        }

        private static Bitmap DecodeWebP(byte[] input, ImageHeader header)
        {
            string executable = decoderPath;
            if (String.IsNullOrEmpty(executable) || !File.Exists(executable))
                throw new FileNotFoundException("The required bundled WebP decoder is unavailable. Reinstall AICON FACTORY.");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = executable;
            start.Arguments = "-pam -o - -- -";
            start.WorkingDirectory = Path.GetDirectoryName(executable);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            using (System.Diagnostics.Process process = new System.Diagnostics.Process())
            {
                process.StartInfo = start;
                Task<Bitmap> output = null;
                Task inputTask = null;
                Task<string> errors = null;
                bool returned = false;
                try
                {
                    if (!process.Start()) throw new InvalidOperationException("The bundled WebP decoder could not start.");
                    output = Task.Factory.StartNew<Bitmap>(delegate
                    {
                        try { return ReadPam(process.StandardOutput.BaseStream, header); }
                        finally { process.StandardOutput.Close(); }
                    }, TaskCreationOptions.LongRunning);
                    errors = Task.Factory.StartNew<string>(delegate { return ReadDiagnostic(process.StandardError); }, TaskCreationOptions.LongRunning);
                    inputTask = Task.Factory.StartNew(delegate
                    {
                        try { process.StandardInput.BaseStream.Write(input, 0, input.Length); }
                        finally { process.StandardInput.Close(); }
                    }, TaskCreationOptions.LongRunning);
                    if (!process.WaitForExit(DecoderTimeoutMilliseconds))
                    {
                        StopProcess(process);
                        throw new InvalidDataException("WebP decoding took too long. Try a smaller or re-exported image.");
                    }
                    try
                    {
                        if (!Task.WaitAll(new Task[] { output, errors, inputTask }, 5000))
                            throw new InvalidDataException("The WebP decoder did not finish cleanly.");
                    }
                    catch (AggregateException ex)
                    {
                        throw new InvalidDataException("The WebP image could not be decoded. It may be damaged or unsupported.", ex.Flatten());
                    }
                    if (process.ExitCode != 0)
                        throw new InvalidDataException("The WebP image could not be decoded. " + errors.Result.Trim());
                    Bitmap bitmap = output.Result;
                    returned = true;
                    return bitmap;
                }
                finally
                {
                    StopProcess(process);
                    // Finish/observe worker tasks before releasing process streams or pixel memory.
                    List<Task> tasks = new List<Task>();
                    if (output != null) tasks.Add(output);
                    if (errors != null) tasks.Add(errors);
                    if (inputTask != null) tasks.Add(inputTask);
                    try { if (tasks.Count > 0) Task.WaitAll(tasks.ToArray(), 5000); }
                    catch (AggregateException) { }
                    if (!returned && output != null)
                    {
                        // Even if terminating a failed decoder takes longer than the cleanup wait,
                        // dispose a bitmap that is returned later instead of leaking native pixels.
                        output.ContinueWith(delegate(Task<Bitmap> completed)
                        {
                            if (completed.Status == TaskStatus.RanToCompletion) completed.Result.Dispose();
                            else if (completed.IsFaulted) GC.KeepAlive(completed.Exception);
                        }, System.Threading.CancellationToken.None,
                            TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                    }
                    foreach (Task pending in tasks)
                    {
                        pending.ContinueWith(delegate(Task completed)
                        {
                            if (completed.IsFaulted) GC.KeepAlive(completed.Exception);
                        }, System.Threading.CancellationToken.None,
                            TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                    }
                }
            }
        }

        private static void StopProcess(System.Diagnostics.Process process)
        {
            try { if (!process.HasExited) { process.Kill(); process.WaitForExit(2000); } }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }

        private static string ReadDiagnostic(StreamReader reader)
        {
            StringBuilder message = new StringBuilder();
            char[] block = new char[1024];
            int read;
            while ((read = reader.Read(block, 0, block.Length)) > 0)
                if (message.Length < 8192) message.Append(block, 0, Math.Min(read, 8192 - message.Length));
            return message.ToString();
        }

        private static Bitmap ReadPam(Stream stream, ImageHeader expected)
        {
            if (ReadAsciiLine(stream) != "P7") throw Damaged("decoded WebP");
            int width = 0, height = 0, depth = 0, maxValue = 0;
            string tuple = String.Empty;
            bool end = false;
            for (int lineCount = 0; lineCount < 20; lineCount++)
            {
                string line = ReadAsciiLine(stream);
                if (line == "ENDHDR") { end = true; break; }
                if (line.StartsWith("#", StringComparison.Ordinal)) continue;
                string[] parts = line.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length != 2) throw Damaged("decoded WebP");
                int number;
                if (parts[0] == "TUPLTYPE") { tuple = parts[1]; continue; }
                if (!Int32.TryParse(parts[1], out number)) throw Damaged("decoded WebP");
                switch (parts[0])
                {
                    case "WIDTH": width = number; break;
                    case "HEIGHT": height = number; break;
                    case "DEPTH": depth = number; break;
                    case "MAXVAL": maxValue = number; break;
                    default: throw Damaged("decoded WebP");
                }
            }
            if (!end || width != expected.Width || height != expected.Height || maxValue != 255 ||
                !((depth == 3 && tuple == "RGB") || (depth == 4 && tuple == "RGB_ALPHA")))
                throw Damaged("decoded WebP");
            CheckDimensions(width, height);
            Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            BitmapData locked = null;
            try
            {
                locked = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                byte[] row = new byte[width * depth];
                byte[] bgra = new byte[width * 4];
                for (int y = 0; y < height; y++)
                {
                    ReadExactly(stream, row, 0, row.Length);
                    for (int x = 0; x < width; x++)
                    {
                        bgra[x * 4] = row[x * depth + 2];
                        bgra[x * 4 + 1] = row[x * depth + 1];
                        bgra[x * 4 + 2] = row[x * depth];
                        bgra[x * 4 + 3] = depth == 4 ? row[x * depth + 3] : (byte)255;
                    }
                    Marshal.Copy(bgra, 0, IntPtr.Add(locked.Scan0, y * locked.Stride), bgra.Length);
                }
                if (stream.ReadByte() != -1) throw Damaged("decoded WebP");
                bitmap.UnlockBits(locked);
                locked = null;
                return bitmap;
            }
            catch
            {
                if (locked != null) bitmap.UnlockBits(locked);
                bitmap.Dispose();
                throw;
            }
        }

        private static string ReadAsciiLine(Stream stream)
        {
            StringBuilder line = new StringBuilder();
            for (int i = 0; i < 256; i++)
            {
                int value = stream.ReadByte();
                if (value == -1) throw Damaged("decoded WebP");
                if (value == 10) return line.ToString().TrimEnd('\r');
                if (value < 9 || value > 126) throw Damaged("decoded WebP");
                line.Append((char)value);
            }
            throw Damaged("decoded WebP");
        }

        private static Rectangle FindVisibleBounds(Bitmap bitmap)
        {
            int left = bitmap.Width, top = bitmap.Height, right = -1, bottom = -1;
            BitmapData data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] row = new byte[bitmap.Width * 4];
                for (int y = 0; y < bitmap.Height; y++)
                {
                    Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, row.Length);
                    for (int x = 0; x < bitmap.Width; x++)
                    {
                        if (row[x * 4 + 3] == 0) continue;
                        if (x < left) left = x;
                        if (x > right) right = x;
                        if (y < top) top = y;
                        if (y > bottom) bottom = y;
                    }
                }
            }
            finally { bitmap.UnlockBits(data); }
            if (right < left || bottom < top)
                throw new InvalidDataException("This image is completely transparent. Choose an image with visible pixels.");
            return Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
        }

        private sealed class UniformRaster : IDisposable
        {
            public Bitmap Bitmap;
            public RectangleF Extent;
            public List<GeometryTrace> Trace;
            public void Dispose() { if (Bitmap != null) Bitmap.Dispose(); }
        }

        private static UniformRaster DrawUniform(Bitmap source, RectangleF sourceBounds,
            float commonScale, int canvasWidth, int canvasHeight, float x, float y,
            string stage, List<GeometryTrace> trace)
        {
            Bitmap output = new Bitmap(canvasWidth, canvasHeight, PixelFormat.Format32bppArgb);
            try
            {
                using (Graphics graphics = Graphics.FromImage(output))
                using (ImageAttributes attributes = new ImageAttributes())
                using (Matrix transform = new Matrix(commonScale, 0, 0, commonScale,
                    x - sourceBounds.X * commonScale, y - sourceBounds.Y * commonScale))
                {
                    graphics.PageUnit = GraphicsUnit.Pixel;
                    graphics.Clear(Color.Transparent);
                    graphics.CompositingMode = CompositingMode.SourceCopy;
                    graphics.CompositingQuality = CompositingQuality.HighQuality;
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.SmoothingMode = SmoothingMode.HighQuality;
                    graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    attributes.SetWrapMode(WrapMode.TileFlipXY);
                    graphics.Transform = transform;
                    // Identical source/destination extents: the matrix is the only
                    // resize. Its M11 and M22 use the same single scale value.
                    PointF[] points = new PointF[] {
                        new PointF(sourceBounds.Left, sourceBounds.Top),
                        new PointF(sourceBounds.Right, sourceBounds.Top),
                        new PointF(sourceBounds.Left, sourceBounds.Bottom)
                    };
                    graphics.DrawImage(source, points, sourceBounds, GraphicsUnit.Pixel, attributes);
                    float[] used = graphics.Transform.Elements;
                    trace.Add(new GeometryTrace {
                        Stage = stage, ScaleX = used[0], ScaleY = used[3],
                        ShearX = used[1], ShearY = used[2],
                        SourceWidth = sourceBounds.Width, SourceHeight = sourceBounds.Height,
                        DestinationX = x, DestinationY = y,
                        DestinationWidth = sourceBounds.Width * commonScale,
                        DestinationHeight = sourceBounds.Height * commonScale,
                        CanvasWidth = canvasWidth, CanvasHeight = canvasHeight
                    });
                }
                return new UniformRaster {
                    Bitmap = output,
                    Extent = new RectangleF(x, y, sourceBounds.Width * commonScale, sourceBounds.Height * commonScale),
                    Trace = trace
                };
            }
            catch { output.Dispose(); throw; }
        }

        private static UniformRaster BuildUniformMaster(Bitmap original, RectangleF bounds)
        {
            List<GeometryTrace> trace = new List<GeometryTrace>();
            UniformRaster current = DrawUniform(original, bounds, 1.0f,
                (int)Math.Ceiling(bounds.Width), (int)Math.Ceiling(bounds.Height), 0, 0, "Trim", trace);
            try
            {
                while (Math.Max(current.Extent.Width, current.Extent.Height) > 1024.0f)
                {
                    UniformRaster next = DrawUniform(current.Bitmap, current.Extent, 0.5f,
                        Math.Max(1, (int)Math.Ceiling(current.Extent.Width * 0.5f)),
                        Math.Max(1, (int)Math.Ceiling(current.Extent.Height * 0.5f)), 0, 0, "MasterHalf", trace);
                    current.Dispose(); current = next;
                }
                return current;
            }
            catch { current.Dispose(); throw; }
        }

        private static UniformRaster RenderUniformFrame(UniformRaster master, int size, List<GeometryTrace> trace)
        {
            int padding = Math.Max(1, (int)Math.Round(size * PaddingFraction, MidpointRounding.AwayFromZero));
            int innerSize = size - padding * 2;
            UniformRaster current = null;
            Bitmap input = master.Bitmap;
            RectangleF extent = master.Extent;
            try
            {
                while (Math.Max(extent.Width, extent.Height) > innerSize * 2.0f)
                {
                    UniformRaster next = DrawUniform(input, extent, 0.5f,
                        Math.Max(1, (int)Math.Ceiling(extent.Width * 0.5f)),
                        Math.Max(1, (int)Math.Ceiling(extent.Height * 0.5f)), 0, 0, "FrameHalf", trace);
                    if (current != null) current.Dispose();
                    current = next; input = current.Bitmap; extent = current.Extent;
                }
                float commonScale = (float)((double)innerSize / Math.Max(extent.Width, extent.Height));
                float width = extent.Width * commonScale;
                float height = extent.Height * commonScale;
                return DrawUniform(input, extent, commonScale, size, size,
                    (size - width) / 2.0f, (size - height) / 2.0f, "Final", trace);
            }
            finally { if (current != null) current.Dispose(); }
        }


        private static byte[] EncodePng(Bitmap bitmap)
        {
            using (MemoryStream stream = new MemoryStream())
            {
                bitmap.Save(stream, ImageFormat.Png);
                return stream.ToArray();
            }
        }

        private static byte[] BuildIcon(Dictionary<int, byte[]> frames)
        {
            SortedSet<int> sizes = new SortedSet<int>(frames.Keys);
            using (MemoryStream stream = new MemoryStream())
            using (BinaryWriter writer = new BinaryWriter(stream))
            {
                writer.Write((ushort)0); // reserved
                writer.Write((ushort)1); // icon, not cursor
                writer.Write((ushort)sizes.Count);
                uint offset = (uint)(6 + 16 * sizes.Count);
                foreach (int size in sizes)
                {
                    byte[] frame = frames[size];
                    writer.Write((byte)(size == 256 ? 0 : size));
                    writer.Write((byte)(size == 256 ? 0 : size));
                    writer.Write((byte)0); // palette entries
                    writer.Write((byte)0); // reserved
                    writer.Write((ushort)1); // color planes
                    writer.Write((ushort)32); // BGRA
                    writer.Write((uint)frame.Length);
                    writer.Write(offset);
                    offset += (uint)frame.Length;
                }
                foreach (int size in sizes) writer.Write(frames[size]);
                writer.Flush();
                return stream.ToArray();
            }
        }

        private static bool FourCC(byte[] data, int start, string value)
        {
            return start >= 0 && start <= data.Length - 4 && data[start] == value[0] &&
                data[start + 1] == value[1] && data[start + 2] == value[2] && data[start + 3] == value[3];
        }
        private static uint ReadU32BE(byte[] data, int start)
        {
            return ((uint)data[start] << 24) | ((uint)data[start + 1] << 16) |
                ((uint)data[start + 2] << 8) | data[start + 3];
        }
        private static uint ReadU32LE(byte[] data, int start)
        {
            return data[start] | ((uint)data[start + 1] << 8) | ((uint)data[start + 2] << 16) | ((uint)data[start + 3] << 24);
        }
        private static int ReadU24LE(byte[] data, int start)
        {
            return data[start] | (data[start + 1] << 8) | (data[start + 2] << 16);
        }
        private static void ReadExactly(Stream stream, byte[] bytes, int offset, int count)
        {
            while (count > 0)
            {
                int read = stream.Read(bytes, offset, count);
                if (read == 0) throw new InvalidDataException("The image is incomplete or truncated.");
                offset += read;
                count -= read;
            }
        }
        private static InvalidDataException Damaged(string format)
        {
            return new InvalidDataException("The " + format + " image is damaged, incomplete, or unsupported.");
        }
        private static uint[] MakeCrcTable()
        {
            uint[] table = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint value = n;
                for (int bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xedb88320U ^ (value >> 1) : value >> 1;
                table[n] = value;
            }
            return table;
        }
        private static uint PngCrc(byte[] data, int start, int count)
        {
            uint crc = 0xffffffffU;
            for (int i = start; i < start + count; i++) crc = CrcTable[(crc ^ data[i]) & 255] ^ (crc >> 8);
            return crc ^ 0xffffffffU;
        }
    }
}
