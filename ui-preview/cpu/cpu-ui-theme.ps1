<#
.SYNOPSIS
    『CPU割り当て』『Edge Box 監視』で共通に使う画面の見た目 (配色・文字・部品)。

.DESCRIPTION
    cpu-console.ps1 / cpu-monitor.ps1 から読み込みます (単独では何もしません)。
    設定や割り当ての処理は一切持たず、表示に使う部品だけをまとめています。

      配色      グレー基調 (背景 #616061 / サイドメニュー #424142 / カード #757475)。
                青 = Windows、緑 = Edge Box、ミントグリーン = 正常、赤 = エラー。文字に使うときは、
                灰色の上でも読めるよう同じ色を明るくしたもの (WinText など) を使う
      文字      日本語は Meiryo UI、英字の見出しは Segoe UI、数値は Cascadia Mono / Consolas
      部品      ボタン・コアのタイル・パネル・左メニュー・状態表示・入力欄の枠・一覧・確認ダイアログ
      アイコン  Windows 標準のアイコンフォント (Segoe Fluent Icons / Segoe MDL2 Assets)。
                無い環境では同じ形を線で描きます
      タイトルバー  Windows 10 (2004 以降) / 11 では背景と同じ色にそろえます (使えない環境では標準のまま)

    Windows PowerShell 5.1 の Add-Type (C# 5) でコンパイルできる書き方に限っています。
#>

# 画面に出すアプリ名と版 (アプリ名は仮。変えるときはここだけ直す)
$UiAppName     = "CNCSCREEN CORE SPLIT"
$UiAppVersion  = "2.0.0"
$UiAppTagline  = "CORE PARTITION CONSOLE"

if (-not ("CoreUi.Theme" -as [type])) {
    $uiSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CoreUi
{
    public enum Tone { Muted, Ok, Warn, Err, Win, Edge, Neutral }
    public enum ButtonKind { Default, Primary, Danger, Ghost }

    // ------------------------------------------------------------------
    //  配色・文字
    // ------------------------------------------------------------------
    public static class Theme
    {
        public static Color Bg           = Rgb(0x616061);   // メイン背景
        public static Color Sidebar      = Rgb(0x424142);   // サイドメニュー
        public static Color Bg2          = Rgb(0x757475);   // 操作バー・監視の上部バー
        public static Color Panel        = Rgb(0x757475);   // カード
        public static Color Raised       = Rgb(0x807F80);   // カードの上で一段明るい面
        public static Color Recess       = Rgb(0x6B6A6B);   // カードの上で一段沈んだ面 (未割当のタイル)
        public static Color Inset        = Rgb(0x4C4B4C);   // 記録・検査結果・一覧の見出しの下地 (色付きの文字を読みやすく)
        public static Color Deep         = Rgb(0x3E3D3E);   // 色付きの面の土台・主要ボタン
        public static Color Control      = Rgb(0x5E5D5E);   // ボタン・入力欄
        public static Color ControlHover = Rgb(0x686768);
        public static Color ControlDown  = Rgb(0x555455);
        public static Color Selection    = Rgb(0x3E3D3E);   // 一覧・選択欄で選んでいる行 (縞の行と見分けられる濃さ)
        public static Color Border       = Rgb(0x8E8D8E);   // 境界線
        public static Color BorderStrong = Rgb(0xB5B4B5);
        public static Color Text         = Rgb(0xFFFFFF);   // メインテキスト
        public static Color SubText      = Rgb(0xFFFFFF);   // サブテキスト (#757475 の上で読めるのは白だけのため、
                                                            //   見出しとの差は文字の大きさ・太さで付ける)
        public static Color Faint        = Rgb(0xA6A5A6);   // 無効
        public static Color Silver       = Rgb(0xF2F2F2);   // 選択・フォーカス (OS の色とは別)
        public static Color Ink          = Rgb(0x1C1C1C);   // 明るい面の上の印 (チェック・つまみ)
        public static Color Win          = Rgb(0x56B4FF);   // Windows
        public static Color Edge         = Rgb(0x6CC851);   // Edge Box (Linux): 緑 (成功の緑 Ok より黄み寄りにして見分ける)
        public static Color Ok           = Rgb(0x43D9A3);   // 成功・稼働
        public static Color Err          = Rgb(0xFF626E);   // エラー
        public static Color Warn         = Rgb(0xE2C16B);   // 注意
        // 文字に使う色 (上の色を明るくしたもの。灰色の面の上でも読める)
        public static Color WinText      = Rgb(0xC0E2FF);
        public static Color EdgeText     = Rgb(0xC6EFB8);
        public static Color OkText       = Rgb(0xA6F3D4);
        public static Color ErrText      = Rgb(0xFFD4D8);
        public static Color WarnText     = Rgb(0xF5E1A6);

        public static string JpFamily = "Meiryo UI";
        public static string LatinFamily = "Segoe UI";
        public static string LatinSemiFamily = "Segoe UI Semibold";
        public static string MonoFamily = "Consolas";
        public static string IconFamily = null;

        public static Font Ui, UiBold, UiSmall, UiMedium, UiTitle, PageTitle, Caps, CapsLarge, Brand, Nav, Mono, MonoSmall, MonoBold, MonoNumber;

        static Theme() { Init(); }

        public static void Init()
        {
            Dictionary<string, bool> fams = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            try {
                using (InstalledFontCollection ifc = new InstalledFontCollection()) {
                    foreach (FontFamily f in ifc.Families) { fams[f.Name] = true; }
                }
            } catch (Exception) { }
            JpFamily        = Pick(fams, new string[] { "Meiryo UI", "Yu Gothic UI", "MS UI Gothic" }, "Meiryo UI");
            LatinFamily     = Pick(fams, new string[] { "Segoe UI" }, JpFamily);
            LatinSemiFamily = Pick(fams, new string[] { "Segoe UI Semibold" }, null);
            MonoFamily      = Pick(fams, new string[] { "Cascadia Mono", "Consolas", "Courier New" }, "Consolas");
            IconFamily      = Pick(fams, new string[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" }, null);

            Ui        = new Font(JpFamily, 9f);
            UiBold    = new Font(JpFamily, 9f, FontStyle.Bold);
            UiSmall   = new Font(JpFamily, 8.25f);
            UiMedium  = new Font(JpFamily, 10f);
            UiTitle   = new Font(JpFamily, 9.75f, FontStyle.Bold);
            PageTitle = Semi(16f);
            Caps      = Semi(7.5f);
            CapsLarge = Semi(8.25f);
            Brand     = Semi(11f);
            Nav       = Semi(10f);
            Mono      = new Font(MonoFamily, 9f);
            MonoSmall = new Font(MonoFamily, 8f);
            MonoBold  = new Font(MonoFamily, 11f, FontStyle.Bold);
            MonoNumber = new Font(MonoFamily, 20f);
        }

        // アプリ名 (左メニュー最上部) の字体と字間。Eurostile がこの PC に入っていればそれを使い、
        // 無ければ同梱の Michroma (Eurostile 系の幅広い角形の字体。SIL Open Font License) を使う。
        // どちらも使えなければ標準の字体の太字に戻す。読み込んだ字体は画面を閉じるまで保持する。
        // 太字の無い字体 (Michroma など) は、文字を WordmarkBolden px (96 dpi 換算) 横にずらして重ね、縦の線を太くして描く
        public static Font Wordmark;
        public static Image AppIcon;   // アプリ名の横のアイコン (images\app-icon.png。無ければ描いたロゴ)
        public static float WordmarkSpacing = 2.4f;
        public static float WordmarkBolden = 0f;
        static PrivateFontCollection wordmarkFonts;
        public static void LoadWordmark(string bundledFile)
        {
            if (Wordmark != null) { return; }
            try {
                string found = null;
                foreach (FontFamily f in new InstalledFontCollection().Families) {
                    if (f.Name.Equals("Eurostile", StringComparison.OrdinalIgnoreCase)) { found = f.Name; break; }
                    if (found == null && f.Name.StartsWith("Eurostile", StringComparison.OrdinalIgnoreCase)) { found = f.Name; }
                }
                if (found != null) {
                    FontFamily ff = new FontFamily(found);
                    bool bold = ff.IsStyleAvailable(FontStyle.Bold);
                    Wordmark = new Font(ff, 12f, bold ? FontStyle.Bold : FontStyle.Regular);
                    WordmarkSpacing = 1.6f;
                    WordmarkBolden = bold ? 0f : 1.3f;
                    return;
                }
            } catch { }
            try {
                if (!string.IsNullOrEmpty(bundledFile)) {
                    wordmarkFonts = new PrivateFontCollection();
                    wordmarkFonts.AddFontFile(bundledFile);
                    if (wordmarkFonts.Families.Length > 0) {
                        Wordmark = new Font(wordmarkFonts.Families[0], 10f, FontStyle.Regular);
                        WordmarkSpacing = 2f;
                        WordmarkBolden = 1.1f;
                        return;
                    }
                }
            } catch { }
            Wordmark = new Font(LatinFamily, 11f, FontStyle.Bold);
            WordmarkSpacing = 2.4f;
            WordmarkBolden = 0f;
        }

        static Font Semi(float size)
        {
            if (LatinSemiFamily != null) { return new Font(LatinSemiFamily, size); }
            return new Font(LatinFamily, size, FontStyle.Bold);
        }

        static string Pick(Dictionary<string, bool> fams, string[] names, string fallback)
        {
            foreach (string n in names) { if (fams.ContainsKey(n)) { return n; } }
            return fallback;
        }

        public static Color Rgb(int v) { return Color.FromArgb(255, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF); }

        public static Color Mix(Color a, Color b, double t)
        {
            if (t < 0) { t = 0; } if (t > 1) { t = 1; }
            return Color.FromArgb(255,
                (int)Math.Round(a.R + (b.R - a.R) * t),
                (int)Math.Round(a.G + (b.G - a.G) * t),
                (int)Math.Round(a.B + (b.B - a.B) * t));
        }

        public static Color Alpha(Color c, int a) { return Color.FromArgb(Math.Max(0, Math.Min(255, a)), c.R, c.G, c.B); }

        // 濃い面か (濃い面の上では選択・ホバーを明るく、明るい面の上では濃くして示す)
        public static bool IsDark(Color c) { return (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) / 255.0 < 0.35; }

        public static Color ToneColor(Tone t)
        {
            switch (t) {
                case Tone.Ok:   return Ok;
                case Tone.Warn: return Warn;
                case Tone.Err:  return Err;
                case Tone.Win:  return Win;
                case Tone.Edge: return Edge;
                case Tone.Neutral: return Silver;
                default:        return SubText;
            }
        }

        public static Color ToneText(Tone t)
        {
            switch (t) {
                case Tone.Ok:   return OkText;
                case Tone.Warn: return WarnText;
                case Tone.Err:  return ErrText;
                case Tone.Win:  return WinText;
                case Tone.Edge: return EdgeText;
                case Tone.Neutral: return Text;
                default:        return SubText;
            }
        }

        // 英数字だけの文字列か (英字用・等幅の文字で描いてよいか)
        public static bool IsAscii(string s)
        {
            if (s == null) { return true; }
            foreach (char ch in s) { if (ch > 0x7E) { return false; } }
            return true;
        }

        public static Color BackOf(Control c)
        {
            Control p = c;
            while (p != null) {
                if (p.BackColor.A == 255) { return p.BackColor; }
                p = p.Parent;
            }
            return Bg;
        }

        public static GraphicsPath Round(RectangleF r, float rad)
        {
            GraphicsPath path = new GraphicsPath();
            if (rad <= 0.1f) { path.AddRectangle(r); return path; }
            float d = rad * 2;
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRound(Graphics g, Rectangle r, float rad, Color fill, Color border)
        {
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF rf = new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1f, r.Height - 1f);
            using (GraphicsPath p = Round(rf, rad)) {
                if (fill.A > 0) { using (SolidBrush b = new SolidBrush(fill)) { g.FillPath(b, p); } }
                if (border.A > 0) { using (Pen pen = new Pen(border)) { g.DrawPath(pen, p); } }
            }
            g.SmoothingMode = old;
        }

        public static void FocusRing(Graphics g, Rectangle r, float rad)
        {
            FillRound(g, r, rad, Color.Empty, Alpha(Text, 190));
        }

        const TextFormatFlags Base = TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;

        public static void DrawText(Graphics g, string s, Font f, Color c, int x, int y)
        {
            TextRenderer.DrawText(g, s, f, new Point(x, y), c, Base);
        }

        public static void DrawText(Graphics g, string s, Font f, Color c, Rectangle r, TextFormatFlags flags)
        {
            TextRenderer.DrawText(g, s, f, r, c, flags | Base);
        }

        public static Size Measure(Graphics g, string s, Font f)
        {
            if (string.IsNullOrEmpty(s)) { return Size.Empty; }
            return TextRenderer.MeasureText(g, s, f, new Size(int.MaxValue, int.MaxValue), Base);
        }

        // 字間を広げた英字 (見出し・タグ用)
        public static int DrawSpaced(Graphics g, string s, Font f, Color c, int x, int y, float spacing)
        {
            float cx = x;
            foreach (char ch in s) {
                string one = ch.ToString();
                TextRenderer.DrawText(g, one, f, new Point((int)Math.Round(cx), y), c, Base);
                cx += TextRenderer.MeasureText(g, one, f, new Size(int.MaxValue, int.MaxValue), Base).Width + spacing;
            }
            return (int)Math.Round(cx - spacing) - x;
        }

        public static int MeasureSpaced(Graphics g, string s, Font f, float spacing)
        {
            float w = 0;
            foreach (char ch in s) {
                w += TextRenderer.MeasureText(g, ch.ToString(), f, new Size(int.MaxValue, int.MaxValue), Base).Width + spacing;
            }
            return (int)Math.Round(Math.Max(0, w - spacing));
        }

        // ロゴ: 枠の中に Windows (青) と Edge Box (緑) を細い隙間で分けて置く
        public static void DrawBrandMark(Graphics g, Rectangle r)
        {
            FillRound(g, r, 3, Deep, BorderStrong);
            int pad = Math.Max(4, r.Width / 5);
            int gap = 2;
            int h = r.Height - pad * 2;
            int w = (r.Width - pad * 2 - gap) / 2;
            Rectangle a = new Rectangle(r.X + pad, r.Y + pad, w, h);
            Rectangle b = new Rectangle(a.Right + gap, a.Y, r.Width - pad * 2 - gap - w, h);
            using (SolidBrush ga = new SolidBrush(Alpha(Win, 50))) { g.FillRectangle(ga, Rectangle.Inflate(a, 1, 1)); }
            using (SolidBrush gb = new SolidBrush(Alpha(Edge, 50))) { g.FillRectangle(gb, Rectangle.Inflate(b, 1, 1)); }
            using (SolidBrush ba = new SolidBrush(Win)) { g.FillRectangle(ba, a); }
            using (SolidBrush bb = new SolidBrush(Edge)) { g.FillRectangle(bb, b); }
        }
    }

    // ------------------------------------------------------------------
    //  アイコン (Windows 標準のアイコンフォント。無ければ線で描く)
    // ------------------------------------------------------------------
    public static class Icons
    {
        static Dictionary<string, char> glyphs = new Dictionary<string, char>();
        static Dictionary<int, Font> fonts = new Dictionary<int, Font>();

        static Icons()
        {
            glyphs.Add("home", '');
            glyphs.Add("settings", '');
            glyphs.Add("log", '');
            glyphs.Add("system", '');
            glyphs.Add("monitor", '');
            glyphs.Add("refresh", '');
            glyphs.Add("external", '');
            glyphs.Add("check", '');
            glyphs.Add("undo", '');
            glyphs.Add("edit", '');
            glyphs.Add("sort", '');
        }

        static Font FontFor(int px)
        {
            Font f;
            if (!fonts.TryGetValue(px, out f)) {
                f = new Font(Theme.IconFamily, px, GraphicsUnit.Pixel);
                fonts[px] = f;
            }
            return f;
        }

        public static void Draw(Graphics g, string key, Rectangle r, Color c)
        {
            if (string.IsNullOrEmpty(key)) { return; }
            char ch;
            if (key != "cores" && Theme.IconFamily != null && glyphs.TryGetValue(key, out ch)) {
                TextRenderer.DrawText(g, ch.ToString(), FontFor(r.Height), r, c,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding |
                    TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
                return;
            }
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float s = r.Width / 16f;
            using (Pen p = new Pen(c, Math.Max(1.1f, 1.25f * s))) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                GraphicsState st = g.Save();
                g.TranslateTransform(r.X, r.Y);
                g.ScaleTransform(s, s);
                p.Width = 1.25f;
                DrawLines(g, key, p, c);
                g.Restore(st);
            }
            g.SmoothingMode = old;
        }

        // 16x16 の座標で描く
        static void DrawLines(Graphics g, string key, Pen p, Color c)
        {
            switch (key) {
                case "home":
                    g.DrawLines(p, new PointF[] { new PointF(2.5f, 7.5f), new PointF(8, 2.5f), new PointF(13.5f, 7.5f) });
                    g.DrawLines(p, new PointF[] { new PointF(4, 6.5f), new PointF(4, 13.5f), new PointF(12, 13.5f), new PointF(12, 6.5f) });
                    g.DrawRectangle(p, 6.5f, 9.5f, 3, 4);
                    break;
                case "cores":
                    g.DrawRectangle(p, 3.5f, 3.5f, 9, 9);
                    g.DrawRectangle(p, 6, 6, 4, 4);
                    for (int i = 0; i < 3; i++) {
                        float o = 5.5f + i * 2.5f;
                        g.DrawLine(p, o, 1, o, 3.5f); g.DrawLine(p, o, 12.5f, o, 15);
                        g.DrawLine(p, 1, o, 3.5f, o); g.DrawLine(p, 12.5f, o, 15, o);
                    }
                    break;
                case "settings":
                    g.DrawEllipse(p, 5.5f, 5.5f, 5, 5);
                    for (int i = 0; i < 8; i++) {
                        double a = Math.PI * i / 4.0;
                        g.DrawLine(p, (float)(8 + Math.Cos(a) * 4.8), (float)(8 + Math.Sin(a) * 4.8),
                                      (float)(8 + Math.Cos(a) * 6.8), (float)(8 + Math.Sin(a) * 6.8));
                    }
                    break;
                case "log":
                    g.DrawLines(p, new PointF[] { new PointF(10, 1.5f), new PointF(3.5f, 1.5f), new PointF(3.5f, 14.5f), new PointF(12.5f, 14.5f), new PointF(12.5f, 4), new PointF(10, 1.5f) });
                    g.DrawLine(p, 6, 7, 10, 7); g.DrawLine(p, 6, 9.5f, 10, 9.5f); g.DrawLine(p, 6, 12, 9, 12);
                    break;
                case "system":
                    g.DrawRectangle(p, 1.5f, 2.5f, 13, 8.5f);
                    g.DrawLine(p, 8, 11, 8, 13.5f); g.DrawLine(p, 5, 13.5f, 11, 13.5f);
                    break;
                case "monitor":
                    g.DrawLines(p, new PointF[] { new PointF(1, 9), new PointF(4.5f, 9), new PointF(6.5f, 4), new PointF(9.5f, 13), new PointF(11.5f, 8), new PointF(15, 8) });
                    break;
                case "refresh":
                    g.DrawArc(p, 2.5f, 2.5f, 11, 11, -60, 290);
                    g.DrawLines(p, new PointF[] { new PointF(10.5f, 1.5f), new PointF(11.5f, 4.5f), new PointF(8.5f, 5.2f) });
                    break;
                case "external":
                    g.DrawLines(p, new PointF[] { new PointF(7, 2.5f), new PointF(2.5f, 2.5f), new PointF(2.5f, 13.5f), new PointF(13.5f, 13.5f), new PointF(13.5f, 9) });
                    g.DrawLine(p, 8, 8, 14, 2); g.DrawLines(p, new PointF[] { new PointF(9.5f, 2), new PointF(14, 2), new PointF(14, 6.5f) });
                    break;
                case "check":
                    g.DrawLines(p, new PointF[] { new PointF(2.5f, 8.5f), new PointF(6, 12), new PointF(13.5f, 4) });
                    break;
                case "undo":
                    g.DrawArc(p, 3.5f, 4.5f, 10, 9, -90, 180);
                    g.DrawLine(p, 8.5f, 13.5f, 5, 13.5f);
                    g.DrawLine(p, 8.5f, 4.5f, 2.5f, 4.5f);
                    g.DrawLines(p, new PointF[] { new PointF(5, 2), new PointF(2.5f, 4.5f), new PointF(5, 7) });
                    break;
                case "edit":
                    g.DrawPolygon(p, new PointF[] { new PointF(11, 2), new PointF(14, 5), new PointF(5.5f, 13.5f), new PointF(2, 14), new PointF(2.5f, 10.5f) });
                    break;
                case "sort":
                    g.DrawLine(p, 5, 2.5f, 5, 13.5f); g.DrawLines(p, new PointF[] { new PointF(2.5f, 5), new PointF(5, 2.5f), new PointF(7.5f, 5) });
                    g.DrawLine(p, 11, 2.5f, 11, 13.5f); g.DrawLines(p, new PointF[] { new PointF(8.5f, 11), new PointF(11, 13.5f), new PointF(13.5f, 11) });
                    break;
                default:
                    using (SolidBrush b = new SolidBrush(c)) { g.FillRectangle(b, 6, 6, 4, 4); }
                    break;
            }
        }
    }

    // ------------------------------------------------------------------
    //  Windows との連携 (タイトルバーを背景の色に、スクロールバーを濃い色にそろえる)
    // ------------------------------------------------------------------
    public static class Native
    {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hwnd, string subApp, string subIdList);
        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

        static int ColorRef(Color c) { return c.R | (c.G << 8) | (c.B << 16); }

        public static void DarkTitleBar(IntPtr hwnd)
        {
            try {
                int on = 1;
                if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) { DwmSetWindowAttribute(hwnd, 19, ref on, 4); }
                int cap = ColorRef(Theme.Bg);     DwmSetWindowAttribute(hwnd, 35, ref cap, 4);   // 見出し部の色 (Windows 11)
                int brd = ColorRef(Theme.Border); DwmSetWindowAttribute(hwnd, 34, ref brd, 4);   // 枠の色
                int txt = ColorRef(Theme.Text);   DwmSetWindowAttribute(hwnd, 36, ref txt, 4);   // 見出しの文字色
            } catch (Exception) { }
        }

        public static void Attach(Form f)
        {
            f.HandleCreated += delegate(object s, EventArgs e) { DarkTitleBar(((Form)s).Handle); };
            if (f.IsHandleCreated) { DarkTitleBar(f.Handle); }
        }

        public static void DarkScroll(Control c)
        {
            try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch (Exception) { }
        }

        public static void SetTheme(IntPtr hwnd, string name)
        {
            try { SetWindowTheme(hwnd, name, null); } catch (Exception) { }
        }
    }

    // ------------------------------------------------------------------
    //  ボタン (通常 / 主要 / 解除などの注意 / 枠なし)
    // ------------------------------------------------------------------
    public class UiButton : Button
    {
        bool hover, down, selected;
        ButtonKind kind = ButtonKind.Default;
        string glyph;

        public UiButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            BackColor = Color.Transparent;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
            Cursor = Cursors.Hand;
            Size = new Size(120, 34);
        }

        [DefaultValue(ButtonKind.Default)]
        public ButtonKind Kind { get { return kind; } set { kind = value; Invalidate(); } }
        public string Glyph { get { return glyph; } set { glyph = value; Invalidate(); } }
        public bool Selected { get { return selected; } set { selected = value; Invalidate(); } }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        public int PreferredWidthFor(int minWidth)
        {
            using (Graphics g = CreateGraphics()) {
                int w = Theme.Measure(g, Text, kind == ButtonKind.Primary ? Theme.UiBold : Font).Width + 36;
                if (!string.IsNullOrEmpty(glyph)) { w += 24; }
                return Math.Max(minWidth, w);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Color fill, border, text;
            Font font = Font;
            if (!Enabled) {
                fill = Theme.Mix(back, Theme.Control, 0.5); border = Theme.Mix(back, Theme.Border, 0.5); text = Theme.Faint;
            } else if (kind == ButtonKind.Primary) {
                font = Theme.UiBold;
                fill = down ? Theme.Mix(Theme.Deep, Theme.Ink, 0.3) : (hover ? Theme.Mix(Theme.Deep, Theme.Text, 0.08) : Theme.Deep);
                border = hover ? Theme.Text : Theme.Mix(Theme.Border, Theme.Text, 0.55);
                text = Theme.Text;
            } else if (kind == ButtonKind.Danger) {
                fill = down ? Theme.ControlDown : (hover ? Theme.Mix(Theme.Deep, Theme.Err, 0.25) : Theme.Mix(Theme.Deep, Theme.Err, 0.15));
                border = hover ? Theme.Err : Theme.Mix(Theme.Border, Theme.Err, 0.45);
                text = hover ? Theme.Text : Theme.ErrText;
            } else if (kind == ButtonKind.Ghost) {
                fill = down ? Theme.ControlDown : (hover ? Theme.Mix(back, Theme.Text, 0.08) : back);
                border = (hover || selected) ? Theme.Border : back;
                text = (hover || selected) ? Theme.Text : Theme.SubText;
            } else {
                fill = down ? Theme.ControlDown : (hover ? Theme.ControlHover : Theme.Control);
                border = hover ? Theme.Silver : Theme.BorderStrong;   // 背景と同じ濃さの面でも輪郭が見えるよう明るい枠
                text = Theme.Text;
            }
            if (selected && Enabled && kind != ButtonKind.Primary) {
                fill = Theme.Mix(Theme.Deep, Theme.Control, 0.35);
                border = Theme.Silver;
                text = Theme.Text;
            }
            Rectangle body = new Rectangle(2, 2, Width - 4, Height - 4);
            if (kind == ButtonKind.Primary && Enabled) {
                Theme.FillRound(g, new Rectangle(1, 1, Width - 2, Height - 2), 4, Color.Empty, Theme.Alpha(Theme.Silver, 38));
            }
            Theme.FillRound(g, body, 3, fill, border);
            if (Focused && ShowFocusCues) { Theme.FocusRing(g, new Rectangle(0, 0, Width, Height), 4); }

            int iconW = string.IsNullOrEmpty(glyph) ? 0 : 16;
            int gap = iconW > 0 ? 8 : 0;
            Size ts = Theme.Measure(g, Text, font);
            int total = iconW + gap + ts.Width;
            int x = Math.Max(10, (Width - total) / 2);
            if (iconW > 0) { Icons.Draw(g, glyph, new Rectangle(x, (Height - 16) / 2, 16, 16), text); }
            Rectangle tr = new Rectangle(x + iconW + gap, 0, Math.Max(1, Width - (x + iconW + gap) - 6), Height);
            Theme.DrawText(g, Text, font, text, tr, TextFormatFlags.VerticalCenter | TextFormatFlags.Left |
                TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // ------------------------------------------------------------------
    //  CPU コアのタイル (1 物理コア = 1 枚。Side: 0 = 未割当 / 1 = Windows / 2 = Edge Box)
    // ------------------------------------------------------------------
    public class CoreTile : Button
    {
        bool hover, down;
        string coreLabel = "";
        int side;
        string kind = "C";
        int[] threads = new int[0];

        public CoreTile()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            BackColor = Color.Transparent;
            Cursor = Cursors.Hand;
            Size = new Size(84, 78);
        }

        public string CoreLabel { get { return coreLabel; } set { coreLabel = value ?? ""; Invalidate(); } }
        public int Side { get { return side; } set { side = value; Invalidate(); } }
        public string Kind { get { return kind; } set { kind = value ?? "C"; Invalidate(); } }
        public int[] Threads { get { return threads; } set { threads = value ?? new int[0]; Invalidate(); } }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        public static string SideName(int s)
        {
            if (s == 1) { return "WINDOWS"; }
            if (s == 2) { return "EDGE BOX"; }
            return "未割当";
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            bool on = side == 1 || side == 2;
            Color accent = side == 1 ? Theme.Win : (side == 2 ? Theme.Edge : Theme.SubText);
            Rectangle body = new Rectangle(2, 2, Width - 4, Height - 4);

            // 割り当て中は色付きの濃い面 (白い文字が読める)、未割当は一段沈んだ灰色
            Color fill = on ? Theme.Mix(Theme.Deep, accent, 0.30) : Theme.Recess;
            if (hover) { fill = Theme.Mix(fill, Theme.Text, 0.05); }
            if (down)  { fill = Theme.Mix(fill, Theme.Ink, 0.3); }
            Color border = on ? Theme.Mix(Theme.Border, accent, hover ? 0.95 : 0.6) : (hover ? Theme.Silver : Theme.BorderStrong);
            Theme.FillRound(g, body, 3, fill, Color.Empty);

            if (on) {
                // 上側だけごく薄く光らせる (割り当て中であることを控えめに示す)
                Rectangle glow = new Rectangle(body.X + 1, body.Y + 1, body.Width - 2, Math.Max(2, body.Height / 2));
                using (LinearGradientBrush lg = new LinearGradientBrush(glow, Theme.Alpha(accent, 34), Theme.Alpha(accent, 0), LinearGradientMode.Vertical)) {
                    g.FillRectangle(lg, glow);
                }
                using (SolidBrush bar = new SolidBrush(accent)) { g.FillRectangle(bar, body.X + 1, body.Y + 5, 2, body.Height - 10); }
                using (SolidBrush halo = new SolidBrush(Theme.Alpha(accent, 45))) { g.FillRectangle(halo, body.X + 3, body.Y + 5, 2, body.Height - 10); }
            }
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen p = new Pen(border)) {
                if (!on) { p.DashPattern = new float[] { 3f, 2f }; }
                using (GraphicsPath path = Theme.Round(new RectangleF(body.X + 0.5f, body.Y + 0.5f, body.Width - 1f, body.Height - 1f), 3)) {
                    g.DrawPath(p, path);
                }
            }
            g.SmoothingMode = old;

            int x = body.X + 11;
            Font lf = Theme.IsAscii(coreLabel) ? Theme.MonoBold : Theme.UiBold;
            Theme.DrawText(g, coreLabel, lf, on ? Theme.Text : Theme.SubText, x, body.Y + 8);
            string tag = SideName(side);
            if (on) { Theme.DrawSpaced(g, tag, Theme.Caps, side == 1 ? Theme.WinText : Theme.EdgeText, x, body.Y + 30, 0.6f); }
            else    { Theme.DrawText(g, tag, Theme.UiSmall, Theme.SubText, x, body.Y + 29); }

            // スレッド (論理 CPU) を小さな枠で並べる
            int cy = body.Bottom - 22;
            int cx = x;
            bool fits = true;
            int[] widths = new int[threads.Length];
            int need = 0;
            for (int i = 0; i < threads.Length; i++) {
                widths[i] = Math.Max(17, Theme.Measure(g, threads[i].ToString(), Theme.MonoSmall).Width + 8);
                need += widths[i] + (i > 0 ? 3 : 0);
            }
            if (x + need > body.Right - 6) { fits = false; }
            if (fits) {
                for (int i = 0; i < threads.Length; i++) {
                    Rectangle c = new Rectangle(cx, cy, widths[i], 15);
                    Theme.FillRound(g, c, 2, on ? Theme.Alpha(accent, 40) : Color.Empty, on ? Theme.Alpha(accent, 150) : Theme.BorderStrong);
                    Theme.DrawText(g, threads[i].ToString(), Theme.MonoSmall, on ? Theme.Text : Theme.SubText, c,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
                    cx += widths[i] + 3;
                }
            } else if (threads.Length > 0) {
                Theme.DrawText(g, threads[0] + "-" + threads[threads.Length - 1], Theme.MonoSmall, on ? Theme.Text : Theme.SubText, x, cy + 1);
            }
            if (Focused && ShowFocusCues) { Theme.FocusRing(g, new Rectangle(0, 0, Width, Height), 4); }
        }
    }

    // ------------------------------------------------------------------
    //  パネル (細い枠 + 見出し)
    // ------------------------------------------------------------------
    public class Card : Panel
    {
        string title, meta;
        int headerHeight = 46;
        Color accent = Color.Empty;
        bool ticks;

        public Card()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Panel;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
            Padding = new Padding(18, headerHeight, 18, 16);
        }

        public string Title { get { return title; } set { title = value; Invalidate(); } }
        public string Meta { get { return meta; } set { meta = value; Invalidate(); } }
        public Color Accent { get { return accent; } set { accent = value; Invalidate(); } }
        public bool CornerTicks { get { return ticks; } set { ticks = value; Invalidate(); } }
        public int HeaderHeight {
            get { return headerHeight; }
            set { headerHeight = value; Padding = new Padding(Padding.Left, value, Padding.Right, Padding.Bottom); Invalidate(); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            using (Pen p = new Pen(Theme.Border)) { g.DrawRectangle(p, 0, 0, Width - 1, Height - 1); }
            if (accent.A > 0) {
                using (SolidBrush b = new SolidBrush(Theme.Alpha(accent, 200))) { g.FillRectangle(b, 1, 1, Width - 2, 1); }
                Rectangle gr = new Rectangle(1, 2, Width - 2, 10);
                using (LinearGradientBrush lg = new LinearGradientBrush(gr, Theme.Alpha(accent, 22), Theme.Alpha(accent, 0), LinearGradientMode.Vertical)) {
                    g.FillRectangle(lg, gr);
                }
            }
            if (ticks) {
                using (Pen tp = new Pen(Theme.Mix(Theme.BorderStrong, Theme.Silver, 0.35))) {
                    int t = 7;
                    g.DrawLine(tp, 0, 0, t, 0); g.DrawLine(tp, 0, 0, 0, t);
                    g.DrawLine(tp, Width - 1, Height - 1, Width - 1 - t, Height - 1); g.DrawLine(tp, Width - 1, Height - 1, Width - 1, Height - 1 - t);
                }
            }
            if (!string.IsNullOrEmpty(title)) {
                Theme.DrawText(g, title, Theme.UiTitle, Theme.Text, Padding.Left, 15);
                if (!string.IsNullOrEmpty(meta)) {
                    int w = Theme.Measure(g, title, Theme.UiTitle).Width;
                    Font mf = Theme.IsAscii(meta) ? Theme.MonoSmall : Theme.UiSmall;
                    Theme.DrawText(g, meta, mf, Theme.SubText, Padding.Left + w + 12, 17);
                }
            }
        }
    }

    // ページの下地 (背景色 + ごく薄い点の格子)
    public class Backdrop : Panel
    {
        bool dots = true;
        public Backdrop()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
        }
        public bool Dots { get { return dots; } set { dots = value; Invalidate(); } }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.DarkScroll(this); }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            if (!dots) { return; }
            using (Bitmap bm = new Bitmap(20, 20)) {
                bm.SetPixel(0, 0, Theme.Mix(BackColor, Theme.Text, 0.075));
                using (TextureBrush tb = new TextureBrush(bm)) {
                    tb.TranslateTransform(AutoScrollPosition.X % 20, AutoScrollPosition.Y % 20);
                    e.Graphics.FillRectangle(tb, ClientRectangle);
                }
            }
        }
        protected override void OnScroll(ScrollEventArgs se) { base.OnScroll(se); Invalidate(); }
        protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); Invalidate(); }
    }

    // ページの見出し (英字の名前 + 日本語の説明)
    public class PageHeader : Control
    {
        string sub;
        public PageHeader()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Height = 70;
        }
        public string SubTitle { get { return sub; } set { sub = value; Invalidate(); } }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.DrawText(g, Text, Theme.PageTitle, Theme.Text, 0, 0);
            if (!string.IsNullOrEmpty(sub)) {
                Theme.DrawText(g, sub, Theme.Ui, Theme.SubText, new Rectangle(1, 36, Width - 2, 22),
                    TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            }
        }
    }

    // ------------------------------------------------------------------
    //  ヘッダー (ロゴ・アプリ名・版・画面名)
    // ------------------------------------------------------------------
    public class HeaderBar : Panel
    {
        string brand = "", version = "", tagline = "", subtitle = "";
        public HeaderBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Height = 60;
        }
        public string Brand { get { return brand; } set { brand = value ?? ""; Invalidate(); } }
        public string Version { get { return version; } set { version = value ?? ""; Invalidate(); } }
        public string Tagline { get { return tagline; } set { tagline = value ?? ""; Invalidate(); } }
        public string SubTitle { get { return subtitle; } set { subtitle = value ?? ""; Invalidate(); } }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            using (Pen p = new Pen(Theme.Border)) { g.DrawLine(p, 0, Height - 1, Width, Height - 1); }
            // 境界線の左端だけ、ごく薄く光らせる
            Rectangle hl = new Rectangle(0, Height - 1, Math.Min(Width, 360), 1);
            using (LinearGradientBrush lg = new LinearGradientBrush(new Rectangle(0, Height - 1, Math.Max(2, hl.Width), 1),
                       Theme.Alpha(Theme.Silver, 110), Theme.Alpha(Theme.Silver, 0), LinearGradientMode.Horizontal)) {
                g.FillRectangle(lg, hl);
            }
            int x = 20;
            Theme.DrawBrandMark(g, new Rectangle(x, (Height - 26) / 2, 26, 26));
            x += 26 + 14;
            int bw = Theme.DrawSpaced(g, brand, Theme.Brand, Theme.Text, x, 13, 3.2f);
            Theme.DrawSpaced(g, tagline, Theme.Caps, Theme.SubText, x + 1, 35, 1.6f);
            int tw = Theme.MeasureSpaced(g, tagline, Theme.Caps, 1.6f);
            x += Math.Max(bw, tw) + 14;
            if (version.Length > 0) {
                string v = "v" + version;
                Size vs = Theme.Measure(g, v, Theme.MonoSmall);
                Rectangle vr = new Rectangle(x, 14, vs.Width + 12, 18);
                Theme.FillRound(g, vr, 2, Theme.Panel, Theme.Border);
                Theme.DrawText(g, v, Theme.MonoSmall, Theme.SubText, vr, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
                x = vr.Right + 16;
            }
            if (subtitle.Length > 0) {
                using (Pen dp = new Pen(Theme.Border)) { g.DrawLine(dp, x, 18, x, Height - 18); }
                Theme.DrawText(g, subtitle, Theme.UiMedium, Theme.Mix(Theme.SubText, Theme.Text, 0.3), new Rectangle(x + 16, 0, Math.Max(10, Width - x - 16), Height),
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            }
        }
    }

    // ------------------------------------------------------------------
    //  左メニュー最上部のアプリ名 (ロゴ + 字間を広げた名前。幅に収まらなければ語の区切りで折り返す)
    // ------------------------------------------------------------------
    public class SideBrand : Control
    {
        public SideBrand()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            TabStop = false;
            Height = 78;
        }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        static Font WordFont { get { return Theme.Wordmark ?? Theme.Brand; } }

        // 字間を広げて 1 行を描く (draw = false なら幅を測るだけ)。同梱の字体は GDI からは見えないため GDI+ で描く。
        // 太らせる場合は文字の輪郭を図形にし、横にずらして 2 回塗る (Windows の自動太字と同じ考え方。
        // 縦の線だけが太くなるため、S や E の横のすき間はつぶれない)
        static int Spaced(Graphics g, string s, Color c, float x, float y, bool draw)
        {
            float cx = x;
            float bolden = Theme.WordmarkBolden * g.DpiX / 96f;
            float em = WordFont.SizeInPoints * g.DpiY / 72f;
            using (SolidBrush b = new SolidBrush(c))
            using (StringFormat sf = (StringFormat)StringFormat.GenericTypographic.Clone()) {
                sf.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
                foreach (char ch in s) {
                    string one = ch.ToString();
                    if (draw && bolden <= 0f) { g.DrawString(one, WordFont, b, cx, y, sf); }
                    else if (draw) {
                        using (GraphicsPath path = new GraphicsPath())
                        using (Matrix shift = new Matrix()) {
                            path.AddString(one, WordFont.FontFamily, (int)WordFont.Style, em, new PointF(cx, y), sf);
                            g.FillPath(b, path);
                            shift.Translate(bolden, 0f);
                            path.Transform(shift);
                            g.FillPath(b, path);
                        }
                    }
                    cx += g.MeasureString(one, WordFont, PointF.Empty, sf).Width + Theme.WordmarkSpacing;
                }
            }
            return (int)Math.Ceiling(Math.Max(0f, cx - Theme.WordmarkSpacing - x));
        }

        List<string> Lines(Graphics g, int width)
        {
            List<string> lines = new List<string>();
            string cur = "";
            foreach (string w in (Text ?? "").Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)) {
                string next = cur.Length == 0 ? w : cur + " " + w;
                if (cur.Length > 0 && Spaced(g, next, Color.Empty, 0, 0, false) > width) { lines.Add(cur); cur = w; }
                else { cur = next; }
            }
            if (cur.Length > 0) { lines.Add(cur); }
            return lines;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(Theme.BackOf(Parent));
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Image icon = Theme.AppIcon;
            int mark = icon != null ? 34 : 26;
            int x = icon != null ? 18 : 22, tx = x + mark + (icon != null ? 10 : 12);
            int lineH = (int)Math.Ceiling(WordFont.GetHeight(g)) + 4;
            List<string> lines = Lines(g, Math.Max(40, Width - tx - 14));
            int top = (Height - Math.Max(1, lines.Count) * lineH) / 2 + 2;
            for (int i = 0; i < lines.Count; i++) { Spaced(g, lines[i], Theme.Text, tx, top + i * lineH, true); }
            g.SmoothingMode = SmoothingMode.None;
            Rectangle markRect = new Rectangle(x, (Height - mark) / 2, mark, mark);
            if (icon != null) {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(icon, markRect);
            } else {
                Theme.DrawBrandMark(g, markRect);
            }
            using (Pen p = new Pen(Theme.Border)) { g.DrawLine(p, 16, Height - 1, Width - 17, Height - 1); }
        }
    }

    // 面の色と 1 本の境界線だけを持つ帯 (サイドバー: 右に線 / 操作バー: 上に線)
    public class Strip : Panel
    {
        AnchorStyles line = AnchorStyles.None;
        public Strip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg2;
        }
        public AnchorStyles Line { get { return line; } set { line = value; Invalidate(); } }
        protected override void OnPaint(PaintEventArgs e)
        {
            using (Pen p = new Pen(Theme.Border)) {
                if ((line & AnchorStyles.Right) != 0)  { e.Graphics.DrawLine(p, Width - 1, 0, Width - 1, Height); }
                if ((line & AnchorStyles.Top) != 0)    { e.Graphics.DrawLine(p, 0, 0, Width, 0); }
                if ((line & AnchorStyles.Bottom) != 0) { e.Graphics.DrawLine(p, 0, Height - 1, Width, Height - 1); }
                if ((line & AnchorStyles.Left) != 0)   { e.Graphics.DrawLine(p, 0, 0, 0, Height); }
            }
        }
    }

    // ------------------------------------------------------------------
    //  左メニューの項目
    // ------------------------------------------------------------------
    public class NavItem : Button
    {
        bool hover, selected;
        string sub, glyph;
        public NavItem()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            BackColor = Theme.Sidebar;
            Cursor = Cursors.Hand;
            Height = 54;
        }
        public string SubText { get { return sub; } set { sub = value; Invalidate(); } }
        public string Glyph { get { return glyph; } set { glyph = value; Invalidate(); } }
        public bool Selected { get { return selected; } set { selected = value; Invalidate(); } }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Rectangle body = new Rectangle(8, 3, Width - 17, Height - 6);
            bool dark = Theme.IsDark(back);
            if (selected) {
                Theme.FillRound(g, body, 3, dark ? Theme.Mix(back, Theme.Text, 0.10) : Theme.Mix(back, Theme.Ink, 0.16),
                    Theme.Mix(back, Theme.Border, dark ? 0.45 : 0.8));
                using (SolidBrush b = new SolidBrush(Theme.Silver)) { g.FillRectangle(b, body.X, body.Y + 10, 2, body.Height - 20); }
                Rectangle gl = new Rectangle(body.X + 2, body.Y + 10, 10, body.Height - 20);
                using (LinearGradientBrush lg = new LinearGradientBrush(gl, Theme.Alpha(Theme.Silver, 42), Theme.Alpha(Theme.Silver, 0), LinearGradientMode.Horizontal)) {
                    g.FillRectangle(lg, gl);
                }
            } else if (hover) {
                Theme.FillRound(g, body, 3, Theme.Mix(back, Theme.Text, dark ? 0.05 : 0.06), Color.Empty);
            }
            Color main = (selected || hover) ? Theme.Text : Theme.SubText;
            Icons.Draw(g, glyph, new Rectangle(body.X + 16, (Height - 18) / 2, 18, 18), selected ? Theme.Text : Theme.SubText);
            int tx = body.X + 48;
            bool hasSub = !string.IsNullOrEmpty(sub);
            Theme.DrawText(g, Text, Theme.Nav, main, tx, hasSub ? body.Y + 8 : (Height - 18) / 2);
            if (hasSub) {
                Theme.DrawText(g, sub, Theme.UiSmall, Theme.SubText,
                    new Rectangle(tx, body.Y + 28, Math.Max(10, body.Right - tx - 6), 18), TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            }
            if (Focused && ShowFocusCues) { Theme.FocusRing(g, new Rectangle(body.X - 2, body.Y - 2, body.Width + 4, body.Height + 4), 4); }
        }
    }

    // ------------------------------------------------------------------
    //  状態表示 (小さな点 + 文字)
    // ------------------------------------------------------------------
    public class StatusChip : Control
    {
        Tone tone = Tone.Muted;
        bool autoFit = true;
        public StatusChip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Font = Theme.Ui;
            Height = 28;
            TabStop = false;
        }
        public Tone Tone { get { return tone; } set { tone = value; Invalidate(); } }
        public bool AutoFit { get { return autoFit; } set { autoFit = value; Fit(); } }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Fit(); Invalidate(); }

        void Fit()
        {
            if (!autoFit) { return; }
            int w;
            using (Graphics g = CreateGraphics()) { w = Theme.Measure(g, Text, Font).Width + 36; }
            if (w == Width) { return; }
            bool right = (Anchor & AnchorStyles.Right) != 0 && (Anchor & AnchorStyles.Left) == 0;
            int oldRight = Right;
            Width = w;
            if (right) { Left = oldRight - w; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Color c = Theme.ToneColor(tone);
            Theme.FillRound(g, new Rectangle(0, 0, Width, Height), 3, Theme.Mix(Theme.Mix(back, Theme.Deep, 0.35), c, 0.10), Theme.Mix(back, c, 0.6));
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int cy = Height / 2;
            using (SolidBrush halo = new SolidBrush(Theme.Alpha(c, 55))) { g.FillEllipse(halo, 8, cy - 5, 10, 10); }
            using (SolidBrush dot = new SolidBrush(c)) { g.FillEllipse(dot, 10, cy - 3, 6, 6); }
            g.SmoothingMode = old;
            Theme.DrawText(g, Text, Font, Theme.Text, new Rectangle(24, 0, Math.Max(1, Width - 30), Height),
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // ------------------------------------------------------------------
    //  論理 CPU の並び (番号順。青 = Windows / 緑 = Edge Box / 枠だけ = 未割当)
    // ------------------------------------------------------------------
    public class CoreStrip : Control
    {
        int[] ids = new int[0];
        int[] sides = new int[0];
        string[] kinds = new string[0];
        int cellHeight = 14;
        public CoreStrip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Height = 54;
            TabStop = false;
        }
        public int CellHeight { get { return cellHeight; } set { cellHeight = Math.Max(6, value); Invalidate(); } }

        // ids = 論理 CPU 番号 (番号順)、s = 割り当て、k = コアの種類 (P / E / C)
        public void SetData(int[] lpIds, int[] s, string[] k)
        {
            ids = lpIds ?? new int[0];
            sides = s ?? new int[0];
            kinds = k ?? new string[0];
            Invalidate();
        }

        string IdText(int i) { return (i < ids.Length ? ids[i] : i).ToString(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            int n = sides.Length;
            if (n == 0) { return; }
            Color back = Theme.BackOf(Parent);
            const int gap = 2;
            float cw = (Width - gap * (n - 1)) / (float)n;
            int railY = 15;
            int top = 23;

            // 上: P コア / E コアの範囲
            bool hybrid = false;
            for (int i = 1; i < n && i < kinds.Length; i++) { if (kinds[i] != kinds[0]) { hybrid = true; } }
            if (hybrid) {
                int start = 0;
                for (int i = 1; i <= n; i++) {
                    if (i == n || i >= kinds.Length || kinds[i] != kinds[start]) {
                        float x0 = start * (cw + gap);
                        float x1 = (i - 1) * (cw + gap) + cw;
                        bool p = kinds[start] == "P";
                        Color rc = p ? Theme.Text : Theme.Faint;
                        using (Pen rp = new Pen(rc)) {
                            g.DrawLine(rp, x0, railY, x1, railY);
                            g.DrawLine(rp, x0, railY - 3, x0, railY);
                            g.DrawLine(rp, x1, railY - 3, x1, railY);
                        }
                        string lbl = p ? "P-CORE" : (kinds[start] == "E" ? "E-CORE" : "CORE");
                        if (x1 - x0 > 50) { Theme.DrawSpaced(g, lbl, Theme.Caps, Theme.SubText, (int)x0 + 2, 0, 1.2f); }
                        start = i;
                    }
                }
            } else {
                top = 4;
            }

            // 中: 論理 CPU 1 つ = 1 マス
            for (int i = 0; i < n; i++) {
                float x = i * (cw + gap);
                RectangleF r = new RectangleF(x, top, cw, cellHeight);
                Color c = sides[i] == 1 ? Theme.Win : (sides[i] == 2 ? Theme.Edge : Color.Empty);
                if (c.IsEmpty) {
                    using (SolidBrush b = new SolidBrush(Theme.Recess)) { g.FillRectangle(b, r); }
                    using (Pen p = new Pen(Theme.Border)) { g.DrawRectangle(p, r.X, r.Y, r.Width - 1, r.Height - 1); }
                } else {
                    using (SolidBrush b = new SolidBrush(Theme.Mix(back, c, 0.82))) { g.FillRectangle(b, r); }
                    using (SolidBrush hi = new SolidBrush(Theme.Alpha(Color.White, 40))) { g.FillRectangle(hi, r.X, r.Y, r.Width, 1); }
                }
            }

            // 下: 番号 (先頭・割り当てが変わる位置・末尾)
            int ly = top + cellHeight + 5;
            int lastRight = -100;
            for (int i = 0; i < n; i++) {
                bool mark = i == 0 || sides[i] != sides[i - 1];
                if (!mark) { continue; }
                string t = IdText(i);
                int x = (int)Math.Round(i * (cw + gap));
                Size ts = Theme.Measure(g, t, Theme.MonoSmall);
                if (x < lastRight + 6) { continue; }
                Color tc = sides[i] == 1 ? Theme.Win : (sides[i] == 2 ? Theme.Edge : Theme.SubText);
                // 番号は白 (読みやすさ優先)。どちら側かは上のマスの色と、この目盛りの色で示す
                using (Pen tp = new Pen(tc, 2f)) { g.DrawLine(tp, x + 1, top + cellHeight + 1, x + 1, top + cellHeight + 4); }
                Theme.DrawText(g, t, Theme.MonoSmall, Theme.Text, x, ly);
                lastRight = x + ts.Width;
            }
            string last = IdText(n - 1);
            Size ls = Theme.Measure(g, last, Theme.MonoSmall);
            int lx = Width - ls.Width;
            if (lx > lastRight + 6 && n > 1) { Theme.DrawText(g, last, Theme.MonoSmall, Theme.SubText, lx, ly); }
        }
    }

    // ------------------------------------------------------------------
    //  片側 (Windows / Edge Box) の要約: コア数・スレッド数を大きな数字で
    // ------------------------------------------------------------------
    public class SideBlock : Control
    {
        string caption = "", name = "", mix = "", range = "";
        int cores, threadCount;
        Tone tone = Tone.Win;
        public SideBlock()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Height = 124;
            TabStop = false;
        }
        public Tone Tone { get { return tone; } set { tone = value; Invalidate(); } }
        public string Caption { get { return caption; } set { caption = value ?? ""; Invalidate(); } }
        public string NameText { get { return name; } set { name = value ?? ""; Invalidate(); } }

        public void SetValues(int coreCount, int threads, string mixText, string rangeText)
        {
            cores = coreCount; threadCount = threads; mix = mixText ?? ""; range = rangeText ?? "";
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Color c = Theme.ToneColor(tone);
            Rectangle r = new Rectangle(0, 0, Width, Height);
            Theme.FillRound(g, r, 3, Theme.Mix(Theme.Deep, c, 0.22), Theme.Mix(Theme.Border, c, 0.45));
            using (SolidBrush bar = new SolidBrush(c)) { g.FillRectangle(bar, 1, 8, 2, Height - 16); }
            using (SolidBrush halo = new SolidBrush(Theme.Alpha(c, 40))) { g.FillRectangle(halo, 3, 8, 2, Height - 16); }

            int x = 20;
            int cw = Theme.DrawSpaced(g, caption, Theme.CapsLarge, Theme.ToneText(tone), x, 14, 1.8f);
            if (name.Length > 0) {
                Theme.DrawText(g, name, Theme.UiSmall, Theme.SubText, new Rectangle(x + cw + 12, 13, Math.Max(10, Width - x - cw - 24), 18),
                    TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            }
            int ny = 38;
            string a = cores.ToString();
            Theme.DrawText(g, a, Theme.MonoNumber, Theme.Text, x - 2, ny);
            int aw = Theme.Measure(g, a, Theme.MonoNumber).Width;
            Theme.DrawText(g, "コア", Theme.Ui, Theme.SubText, x + aw + 4, ny + 14);
            int bx = x + aw + 4 + Theme.Measure(g, "コア", Theme.Ui).Width + 22;
            string b = threadCount.ToString();
            Theme.DrawText(g, b, Theme.MonoNumber, Theme.Text, bx - 2, ny);
            int bw2 = Theme.Measure(g, b, Theme.MonoNumber).Width;
            Theme.DrawText(g, "スレッド", Theme.Ui, Theme.SubText, bx + bw2 + 4, ny + 14);

            using (Pen sp = new Pen(Theme.Mix(Theme.Mix(Theme.Deep, c, 0.22), Theme.Border, 0.6))) { g.DrawLine(sp, x, Height - 34, Width - 16, Height - 34); }
            Theme.DrawText(g, range.Length > 0 ? range : "CPU -", Theme.Mono, Theme.Text, x, Height - 25);
            if (mix.Length > 0) {
                Size ms = Theme.Measure(g, mix, Theme.Mono);
                Theme.DrawText(g, mix, Theme.Mono, Theme.SubText, Width - 16 - ms.Width, Height - 25);
            }
        }
    }

    // 凡例 (■ Windows ■ Edge Box □ 未割当)
    public class Legend : Control
    {
        public Legend()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Size = new Size(330, 22);
            TabStop = false;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            string[] names = new string[] { "WINDOWS", "EDGE BOX", "未割当" };
            Color[] cols = new Color[] { Theme.Win, Theme.Edge, Color.Empty };
            int total = 0;
            int[] ws = new int[3];
            for (int i = 0; i < 3; i++) {
                ws[i] = 18 + (i < 2 ? Theme.MeasureSpaced(g, names[i], Theme.Caps, 1.2f) : Theme.Measure(g, names[i], Theme.UiSmall).Width);
                total += ws[i] + (i > 0 ? 18 : 0);
            }
            int x = Math.Max(0, Width - total);
            int cy = Height / 2;
            for (int i = 0; i < 3; i++) {
                Rectangle sw = new Rectangle(x, cy - 5, 10, 10);
                if (cols[i].IsEmpty) {
                    using (Pen p = new Pen(Theme.BorderStrong)) { p.DashPattern = new float[] { 2f, 1.5f }; g.DrawRectangle(p, sw.X, sw.Y, sw.Width - 1, sw.Height - 1); }
                    Theme.DrawText(g, names[i], Theme.UiSmall, Theme.SubText, x + 16, cy - 8);
                } else {
                    using (SolidBrush b = new SolidBrush(cols[i])) { g.FillRectangle(b, sw); }
                    Theme.DrawSpaced(g, names[i], Theme.Caps, i == 0 ? Theme.WinText : Theme.EdgeText, x + 16, cy - 7, 1.2f);
                }
                x += ws[i] + 18;
            }
        }
    }

    // メモリの配分 (Windows に残る量 / Edge Box に渡す量)
    public class MemoryBar : Control
    {
        double total, guest;
        public MemoryBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Height = 8;
            TabStop = false;
        }
        public void SetValues(double totalGB, double guestGB) { total = totalGB; guest = guestGB; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Rectangle r = new Rectangle(0, 0, Width, Height);
            using (SolidBrush b = new SolidBrush(Theme.Control)) { g.FillRectangle(b, r); }
            if (total > 0) {
                double gg = Math.Max(0, Math.Min(total, guest));
                int wg = (int)Math.Round(Width * gg / total);
                int wh = Width - wg;
                using (SolidBrush bw = new SolidBrush(Theme.Mix(back, Theme.Win, 0.75))) { g.FillRectangle(bw, 0, 0, Math.Max(0, wh - 1), Height); }
                using (SolidBrush be = new SolidBrush(Theme.Mix(back, Theme.Edge, 0.75))) { g.FillRectangle(be, wh + 1, 0, Math.Max(0, wg - 1), Height); }
            }
        }
    }

    // ------------------------------------------------------------------
    //  入力欄の枠 (TextBox / NumericUpDown を包む。フォーカス中は枠を明るく)
    // ------------------------------------------------------------------
    public class FieldFrame : Panel
    {
        Control inner;
        Panel clip;
        int hiddenRight;
        bool focused;
        public FieldFrame()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Control;
            Padding = new Padding(9, 0, 9, 0);
            Size = new Size(200, 32);
            Cursor = Cursors.IBeam;
        }
        public Control Inner { get { return inner; } }

        public void Wrap(Control c) { Wrap(c, 0); }

        // hidden = 右端を隠す幅 (NumericUpDown の標準の ▲▼ を枠の外に出して見えなくする)
        public void Wrap(Control c, int hidden)
        {
            inner = c;
            hiddenRight = Math.Max(0, hidden);
            c.BackColor = BackColor;
            c.ForeColor = Theme.Text;
            if (hiddenRight > 0) {
                clip = new Panel();
                clip.BackColor = BackColor;
                clip.Click += delegate(object s, EventArgs e) { inner.Focus(); };
                Controls.Add(clip);
                clip.Controls.Add(c);
            } else {
                Controls.Add(c);
            }
            c.Enter += delegate(object s, EventArgs e) { focused = true; Invalidate(); };
            c.Leave += delegate(object s, EventArgs e) { focused = false; Invalidate(); };
            PerformLayout();
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (inner != null) {
                int h = inner.Height;
                Rectangle area = new Rectangle(Padding.Left, Math.Max(0, (Height - h) / 2), Math.Max(10, Width - Padding.Left - Padding.Right), h);
                if (clip != null) {
                    clip.Bounds = area;
                    inner.SetBounds(0, 0, area.Width + hiddenRight, h);
                } else {
                    inner.Bounds = area;
                }
            }
        }

        protected override void OnClick(EventArgs e) { base.OnClick(e); if (inner != null) { inner.Focus(); } }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Color c = !Enabled ? Theme.Mix(Theme.Border, Theme.Bg, 0.3) : (focused ? Theme.Silver : Theme.BorderStrong);
            using (Pen p = new Pen(c)) { e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1); }
        }
    }

    // ------------------------------------------------------------------
    //  選択欄 (標準の ComboBox の枠と ▼ だけを上から描き直す)
    // ------------------------------------------------------------------
    public class DarkComboBox : ComboBox
    {
        bool hover, focusedNow;
        public DarkComboBox()
        {
            FlatStyle = FlatStyle.Flat;
            BackColor = Theme.Control;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
            DrawMode = DrawMode.OwnerDrawFixed;
            ItemHeight = 22;
        }

        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            Graphics g = e.Graphics;
            bool edit = (e.State & DrawItemState.ComboBoxEdit) != 0;
            bool sel = (e.State & DrawItemState.Selected) != 0 && !edit;
            using (SolidBrush b = new SolidBrush(sel ? Theme.Selection : BackColor)) { g.FillRectangle(b, e.Bounds); }
            if (sel) { using (SolidBrush a = new SolidBrush(Theme.Silver)) { g.FillRectangle(a, e.Bounds.X, e.Bounds.Y + 3, 3, e.Bounds.Height - 6); } }
            if (e.Index >= 0 && e.Index < Items.Count) {
                Rectangle tr = new Rectangle(e.Bounds.X + (edit ? 2 : 8), e.Bounds.Y, e.Bounds.Width - 10, e.Bounds.Height);
                Theme.DrawText(g, GetItemText(Items[e.Index]), Font, Enabled ? ForeColor : Theme.Faint, tr,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
            }
        }

        protected override void OnEnter(EventArgs e) { focusedNow = true; Invalidate(); base.OnEnter(e); }
        protected override void OnLeave(EventArgs e) { focusedNow = false; Invalidate(); base.OnLeave(e); }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.SetTheme(Handle, "DarkMode_CFD"); }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == 0x000F && DropDownStyle != ComboBoxStyle.Simple) {   // WM_PAINT の後に枠と ▼ を描き直す
                using (Graphics g = Graphics.FromHwnd(Handle)) {
                    Rectangle r = ClientRectangle;
                    Color border = !Enabled ? Theme.Mix(Theme.Border, Theme.Bg, 0.3) : ((focusedNow || hover) ? Theme.Silver : Theme.BorderStrong);
                    using (Pen inner = new Pen(BackColor)) { g.DrawRectangle(inner, 1, 1, r.Width - 3, r.Height - 3); }
                    using (Pen p = new Pen(border)) { g.DrawRectangle(p, 0, 0, r.Width - 1, r.Height - 1); }
                    int bw = SystemInformation.VerticalScrollBarWidth + 2;
                    Rectangle br = new Rectangle(r.Width - bw - 1, 1, bw, r.Height - 2);
                    using (SolidBrush bb = new SolidBrush(hover && Enabled ? Theme.ControlHover : BackColor)) { g.FillRectangle(bb, br); }
                    using (Pen sp = new Pen(Theme.Border)) { g.DrawLine(sp, br.X, br.Y + 4, br.X, br.Bottom - 5); }
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    float cx = br.X + br.Width / 2f, cy = br.Y + br.Height / 2f;
                    using (Pen ap = new Pen(Enabled ? Theme.SubText : Theme.Faint, 1.4f)) {
                        g.DrawLines(ap, new PointF[] { new PointF(cx - 4, cy - 2), new PointF(cx, cy + 2), new PointF(cx + 4, cy - 2) });
                    }
                }
            }
        }
    }

    // チェックボックス (四角)
    public class DarkCheckBox : CheckBox
    {
        bool hover;
        Color accent = Theme.Silver;
        public DarkCheckBox()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
            Cursor = Cursors.Hand;
            Height = 26;
        }
        public Color Accent { get { return accent; } set { accent = value; Invalidate(); } }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Rectangle box = new Rectangle(3, (Height - 16) / 2, 16, 16);
            Color fill = Checked ? Theme.Mix(back, accent, 0.9) : Theme.Control;
            Color border = Checked ? accent : (hover ? Theme.Silver : Theme.BorderStrong);
            if (!Enabled) { fill = Theme.Mix(back, Theme.Control, 0.5); border = Theme.Border; }
            Theme.FillRound(g, box, 2, fill, border);
            if (Checked) {
                SmoothingMode old = g.SmoothingMode;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (Pen p = new Pen(Theme.Ink, 2f)) {
                    g.DrawLines(p, new PointF[] { new PointF(box.X + 4, box.Y + 8.5f), new PointF(box.X + 7, box.Y + 11.5f), new PointF(box.X + 12.5f, box.Y + 5) });
                }
                g.SmoothingMode = old;
            }
            if (Focused && ShowFocusCues) { Theme.FocusRing(g, Rectangle.Inflate(box, 3, 3), 3); }
            Theme.DrawText(g, Text, Font, Enabled ? ForeColor : Theme.Faint, new Rectangle(box.Right + 9, 0, Math.Max(1, Width - box.Right - 9), Height),
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // オン / オフの切り替え (小さなスイッチ)
    public class ToggleSwitch : CheckBox
    {
        bool hover;
        public ToggleSwitch()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
            Cursor = Cursors.Hand;
            Height = 26;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Rectangle track = new Rectangle(3, (Height - 16) / 2, 30, 16);
            Color fill = Checked ? Theme.Mix(back, Theme.Silver, 0.85) : Theme.Control;
            Color border = Checked ? Theme.Silver : (hover ? Theme.Silver : Theme.BorderStrong);
            Theme.FillRound(g, track, 8, fill, border);
            SmoothingMode old = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int kx = Checked ? track.Right - 14 : track.X + 3;
            using (SolidBrush k = new SolidBrush(Checked ? Theme.Ink : Theme.SubText)) { g.FillEllipse(k, kx, track.Y + 3, 10, 10); }
            g.SmoothingMode = old;
            if (Focused && ShowFocusCues) { Theme.FocusRing(g, Rectangle.Inflate(track, 3, 3), 10); }
            Theme.DrawText(g, Text, Font, ForeColor, new Rectangle(track.Right + 10, 0, Math.Max(1, Width - track.Right - 10), Height),
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // 一覧 (詳細表示の ListView を画面の配色で描く)
    public class DarkListView : ListView
    {
        const int LVM_GETHEADER = 0x101F;
        public DarkListView()
        {
            OwnerDraw = true;
            DoubleBuffered = true;
            BackColor = Theme.Panel;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
            BorderStyle = BorderStyle.None;
            FullRowSelect = true;
            HideSelection = false;
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.DarkScroll(this);
            IntPtr header = Native.SendMessage(Handle, LVM_GETHEADER, IntPtr.Zero, IntPtr.Zero);
            if (header != IntPtr.Zero) { Native.SetTheme(header, "DarkMode_ItemsView"); }
            FillLastColumn();
        }

        protected override void OnResize(EventArgs e) { base.OnResize(e); FillLastColumn(); }

        // 最後の列を残りの幅いっぱいに広げる (見出しの右に空きを作らない)
        public void FillLastColumn()
        {
            if (View != View.Details || Columns.Count == 0 || !IsHandleCreated) { return; }
            int used = 0;
            for (int i = 0; i < Columns.Count - 1; i++) { used += Columns[i].Width; }
            int rest = ClientSize.Width - used;
            ColumnHeader last = Columns[Columns.Count - 1];
            if (rest > 40 && last.Width != rest) { last.Width = rest; }
        }

        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            Graphics g = e.Graphics;
            using (SolidBrush b = new SolidBrush(Theme.Inset)) { g.FillRectangle(b, e.Bounds); }
            using (Pen p = new Pen(Theme.Border)) {
                g.DrawLine(p, e.Bounds.X, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                g.DrawLine(p, e.Bounds.Right - 1, e.Bounds.Y + 5, e.Bounds.Right - 1, e.Bounds.Bottom - 6);
            }
            Rectangle tr = new Rectangle(e.Bounds.X + 9, e.Bounds.Y, e.Bounds.Width - 14, e.Bounds.Height);
            Theme.DrawText(g, e.Header.Text, Theme.UiSmall, Theme.SubText, tr, TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }

        protected override void OnDrawItem(DrawListViewItemEventArgs e)
        {
            if (View != View.Details) { e.DrawDefault = true; }
        }

        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            Graphics g = e.Graphics;
            bool sel = e.Item.Selected;
            Color bg = sel ? Theme.Selection : ((e.ItemIndex % 2) == 1 ? Theme.Mix(Theme.Panel, Theme.Bg, 0.4) : Theme.Panel);
            using (SolidBrush b = new SolidBrush(bg)) { g.FillRectangle(b, e.Bounds); }
            if (sel && e.ColumnIndex == 0) { using (SolidBrush a = new SolidBrush(Theme.Silver)) { g.FillRectangle(a, e.Bounds.X, e.Bounds.Y + 3, 3, e.Bounds.Height - 6); } }
            string t = e.SubItem != null ? e.SubItem.Text : "";
            Rectangle tr = new Rectangle(e.Bounds.X + 9, e.Bounds.Y, Math.Max(1, e.Bounds.Width - 14), e.Bounds.Height);
            Theme.DrawText(g, t, Font, e.ColumnIndex == 0 || sel ? Theme.Text : Theme.Mix(Theme.SubText, Theme.Text, 0.35), tr,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // 一覧 (1 列の ListBox を画面の配色で描く)
    public class DarkListBox : ListBox
    {
        public DarkListBox()
        {
            DrawMode = DrawMode.OwnerDrawFixed;
            ItemHeight = 24;
            BorderStyle = BorderStyle.None;
            IntegralHeight = false;
            BackColor = Theme.Panel;
            ForeColor = Theme.Text;
            Font = Theme.Ui;
        }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Native.DarkScroll(this); }
        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            if (e.Index < 0) { return; }
            Graphics g = e.Graphics;
            bool sel = (e.State & DrawItemState.Selected) != 0;
            using (SolidBrush b = new SolidBrush(sel ? Theme.Selection : ((e.Index % 2) == 1 ? Theme.Mix(Theme.Panel, Theme.Bg, 0.4) : Theme.Panel))) {
                g.FillRectangle(b, e.Bounds);
            }
            if (sel) { using (SolidBrush a = new SolidBrush(Theme.Silver)) { g.FillRectangle(a, e.Bounds.X, e.Bounds.Y + 3, 3, e.Bounds.Height - 6); } }
            Rectangle tr = new Rectangle(e.Bounds.X + 10, e.Bounds.Y, e.Bounds.Width - 14, e.Bounds.Height);
            Theme.DrawText(g, GetItemText(Items[e.Index]), Font, Theme.Text, tr,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        }
    }

    // ------------------------------------------------------------------
    //  確認・お知らせのダイアログ (MessageBox と同じ戻り値)
    // ------------------------------------------------------------------
    class MessageGlyph : Control
    {
        public Tone Tone = Tone.Neutral;
        public string Mark = "i";
        public MessageGlyph()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            Size = new Size(34, 34);
            TabStop = false;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color back = Theme.BackOf(Parent);
            g.Clear(back);
            Color c = Theme.ToneColor(Tone);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush b = new SolidBrush(Theme.Mix(Theme.Deep, c, 0.18))) { g.FillEllipse(b, 1, 1, 31, 31); }
            using (Pen p = new Pen(Theme.Mix(back, c, 0.75), 1.2f)) { g.DrawEllipse(p, 1, 1, 31, 31); }
            Theme.DrawText(g, Mark, Theme.MonoBold, Theme.ToneText(Tone), new Rectangle(0, 0, 34, 34), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }

    // ダイアログの本文 (測る・描くを同じ方法で行い、行が欠けないようにする)
    class MessageText : Control
    {
        const TextFormatFlags Flags = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.Left | TextFormatFlags.Top;
        public MessageText()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            TabStop = false;
        }
        public Size Fit(int maxWidth)
        {
            Size s = TextRenderer.MeasureText(Text, Font, new Size(maxWidth, int.MaxValue), Flags);
            Size = new Size(Math.Min(maxWidth, s.Width + 2), s.Height + 2);
            return Size;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Theme.BackOf(Parent));
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(0, 0, Width, Height), ForeColor, Flags);
        }
    }

    public static class MessageDialog
    {
        public static DialogResult Show(string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon)
        {
            Form owner = Form.ActiveForm;
            if (owner != null && (!owner.Visible || !owner.Enabled)) { owner = null; }
            using (Form f = new Form()) {
                f.Text = caption;
                f.FormBorderStyle = FormBorderStyle.FixedDialog;
                f.MaximizeBox = false;
                f.MinimizeBox = false;
                f.ShowIcon = false;
                f.ShowInTaskbar = owner == null;
                f.StartPosition = owner != null ? FormStartPosition.CenterParent : FormStartPosition.CenterScreen;
                f.TopMost = owner == null || owner.TopMost;
                f.BackColor = Theme.Panel;
                f.ForeColor = Theme.Text;
                f.Font = Theme.Ui;
                f.KeyPreview = true;
                Native.Attach(f);

                MessageGlyph mg = new MessageGlyph();
                if (icon == MessageBoxIcon.Warning) { mg.Tone = Tone.Warn; mg.Mark = "!"; }
                else if (icon == MessageBoxIcon.Error) { mg.Tone = Tone.Err; mg.Mark = "×"; }
                else if (icon == MessageBoxIcon.Question) { mg.Tone = Tone.Neutral; mg.Mark = "?"; }
                else { mg.Tone = Tone.Neutral; mg.Mark = "i"; }
                mg.Location = new Point(26, 26);
                f.Controls.Add(mg);

                MessageText lbl = new MessageText();
                lbl.Font = Theme.UiMedium;
                lbl.ForeColor = Theme.Text;
                lbl.Text = text ?? "";
                lbl.Location = new Point(76, 32);
                f.Controls.Add(lbl);
                Size ts = lbl.Fit(560);

                Strip bar = new Strip();
                bar.Line = AnchorStyles.Top;
                bar.BackColor = Theme.Bg;
                bar.Dock = DockStyle.Bottom;
                bar.Height = 62;
                f.Controls.Add(bar);

                List<UiButton> btns = new List<UiButton>();
                if (buttons == MessageBoxButtons.YesNo || buttons == MessageBoxButtons.YesNoCancel) {
                    btns.Add(Make("はい", DialogResult.Yes, ButtonKind.Primary));
                    btns.Add(Make("いいえ", DialogResult.No, ButtonKind.Default));
                    if (buttons == MessageBoxButtons.YesNoCancel) { btns.Add(Make("キャンセル", DialogResult.Cancel, ButtonKind.Default)); }
                } else if (buttons == MessageBoxButtons.OKCancel) {
                    btns.Add(Make("OK", DialogResult.OK, ButtonKind.Primary));
                    btns.Add(Make("キャンセル", DialogResult.Cancel, ButtonKind.Default));
                } else {
                    btns.Add(Make("OK", DialogResult.OK, ButtonKind.Primary));
                }
                int cw = Math.Max(400, 76 + ts.Width + 34);
                int ch = 30 + Math.Max(34, ts.Height) + 30 + bar.Height;
                f.ClientSize = new Size(cw, ch);
                int bx = cw - 18;
                for (int i = btns.Count - 1; i >= 0; i--) {
                    UiButton b = btns[i];
                    b.Width = b.PreferredWidthFor(96);
                    bx -= b.Width;
                    b.Location = new Point(bx, 14);
                    bx -= 8;
                    bar.Controls.Add(b);
                }
                f.AcceptButton = btns[0];
                f.CancelButton = btns[btns.Count - 1];
                f.Shown += delegate(object s, EventArgs e) { btns[0].Focus(); };
                f.KeyDown += delegate(object s, KeyEventArgs e) {
                    if (e.Control && e.KeyCode == Keys.C) {
                        try { Clipboard.SetText(caption + Environment.NewLine + Environment.NewLine + text); } catch (Exception) { }
                        e.Handled = true;
                    } else if (buttons == MessageBoxButtons.YesNo || buttons == MessageBoxButtons.YesNoCancel) {
                        if (e.KeyCode == Keys.Y) { f.DialogResult = DialogResult.Yes; }
                        else if (e.KeyCode == Keys.N) { f.DialogResult = DialogResult.No; }
                    }
                };
                DialogResult r = owner != null ? f.ShowDialog(owner) : f.ShowDialog();
                if (buttons == MessageBoxButtons.YesNo && r != DialogResult.Yes) { r = DialogResult.No; }
                if (buttons == MessageBoxButtons.OK) { r = DialogResult.OK; }
                return r;
            }
        }

        static UiButton Make(string text, DialogResult res, ButtonKind kind)
        {
            UiButton b = new UiButton();
            b.Text = text;
            b.DialogResult = res;
            b.Kind = kind;
            b.Height = 34;
            return b;
        }
    }

    // ------------------------------------------------------------------
    //  画面全体の仕上げ (タイトルバー・ツールチップ)
    // ------------------------------------------------------------------
    public static class Styler
    {
        public static void Form(Form f)
        {
            f.BackColor = Theme.Bg;
            f.ForeColor = Theme.Text;
            f.Font = Theme.Ui;
            Native.Attach(f);
        }

        public static ToolTip CreateToolTip()
        {
            ToolTip tt = new ToolTip();
            tt.OwnerDraw = true;
            tt.InitialDelay = 450;
            tt.AutoPopDelay = 12000;
            tt.Popup += delegate(object s, PopupEventArgs e) {
                string t = ((ToolTip)s).GetToolTip(e.AssociatedControl);
                Size sz = TextRenderer.MeasureText(t, Theme.Ui, new Size(420, 0), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                e.ToolTipSize = new Size(Math.Min(440, sz.Width + 20), sz.Height + 14);
            };
            tt.Draw += delegate(object s, DrawToolTipEventArgs e) {
                using (SolidBrush b = new SolidBrush(Theme.Inset)) { e.Graphics.FillRectangle(b, e.Bounds); }
                using (Pen p = new Pen(Theme.BorderStrong)) { e.Graphics.DrawRectangle(p, 0, 0, e.Bounds.Width - 1, e.Bounds.Height - 1); }
                TextRenderer.DrawText(e.Graphics, e.ToolTipText, Theme.Ui, new Rectangle(10, 7, e.Bounds.Width - 20, e.Bounds.Height - 14), Theme.Text,
                    TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.Left);
            };
            return tt;
        }
    }
}
'@
    if ($PSVersionTable.PSEdition -eq "Core") {
        # PowerShell 7 では WinForms の型が分かれた参照先にあるため、それも渡す (版の違いの警告は無視する)
        $uiRefs = @("System.Windows.Forms", "System.Windows.Forms.Primitives", "System.Drawing", "System.Drawing.Primitives",
                    "System.Drawing.Common", "System.ComponentModel.Primitives", "System.ComponentModel.TypeConverter",
                    "System.Collections", "System.Runtime.InteropServices", "Microsoft.Win32.Primitives", "System.Private.Windows.Core")
        Add-Type -TypeDefinition $uiSource -ReferencedAssemblies $uiRefs -IgnoreWarnings -ErrorAction Stop
    } else {
        # Windows PowerShell は警告もエラー扱いにするため、警告では止めない (文法の誤りは従来どおり止まる)
        Add-Type -TypeDefinition $uiSource -ReferencedAssemblies @("System", "System.Windows.Forms", "System.Drawing") -IgnoreWarnings -ErrorAction Stop
    }
}
# アプリ名の字体 (同梱: fonts\Michroma-Regular.ttf。無ければ Eurostile か標準の字体で表示する)
$uiWordmarkFile = Join-Path $PSScriptRoot "fonts\Michroma-Regular.ttf"
try { [CoreUi.Theme]::LoadWordmark($(if (Test-Path -LiteralPath $uiWordmarkFile) { $uiWordmarkFile } else { "" })) } catch { }
# アプリ名の横のアイコン。ファイルを開いたままにしないよう、読み込んだ内容から複製して持つ
$uiAppIconFile = Join-Path $PSScriptRoot "images\app-icon.png"
if (-not [CoreUi.Theme]::AppIcon -and (Test-Path -LiteralPath $uiAppIconFile)) {
    try {
        $uiIconStream = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($uiAppIconFile))
        $uiIconImage = [System.Drawing.Image]::FromStream($uiIconStream)
        [CoreUi.Theme]::AppIcon = New-Object System.Drawing.Bitmap($uiIconImage)
        $uiIconImage.Dispose(); $uiIconStream.Dispose()
    } catch { }
}

# ============================================================
#  PowerShell 側の小さな部品
# ============================================================
function New-UiLabel([string]$Text, [int]$X, [int]$Y, [int]$W = 0, [string]$Style = "body", [int]$H = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.UseMnemonic = $false
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    switch ($Style) {
        "sub"    { $l.Font = [CoreUi.Theme]::Ui;        $l.ForeColor = [CoreUi.Theme]::SubText }
        "small"  { $l.Font = [CoreUi.Theme]::UiSmall;   $l.ForeColor = [CoreUi.Theme]::SubText }
        "strong" { $l.Font = [CoreUi.Theme]::UiBold;    $l.ForeColor = [CoreUi.Theme]::Text }
        "mono"   { $l.Font = [CoreUi.Theme]::Mono;      $l.ForeColor = [CoreUi.Theme]::Text }
        "monosub"{ $l.Font = [CoreUi.Theme]::MonoSmall; $l.ForeColor = [CoreUi.Theme]::SubText }
        "medium" { $l.Font = [CoreUi.Theme]::UiMedium;  $l.ForeColor = [CoreUi.Theme]::Text }
        default  { $l.Font = [CoreUi.Theme]::Ui;        $l.ForeColor = [CoreUi.Theme]::Text }
    }
    if ($W -gt 0) {
        $l.AutoSize = $false
        $l.AutoEllipsis = $true
        $l.Size = New-Object System.Drawing.Size($W, $(if ($H -gt 0) { $H } else { 22 }))
    } else {
        $l.AutoSize = $true
    }
    return $l
}

function New-UiButton([string]$Text, [int]$W = 120, [string]$Kind = "Default", [string]$Glyph = "") {
    $b = New-Object CoreUi.UiButton
    $b.Text = $Text
    $b.Kind = $Kind
    if ($Glyph) { $b.Glyph = $Glyph }
    $b.Size = New-Object System.Drawing.Size($W, 34)
    return $b
}

# TextBox / NumericUpDown を枠で包む。戻り値は枠 (位置・大きさは枠に設定する)。
# NumericUpDown は標準の ▲▼ を枠の外へ出して隠す (値はキーの ↑↓・ホイール・呼び出し側の − / + で変える)
function New-UiField($Inner, [int]$X, [int]$Y, [int]$W, [int]$H = 32, $Font = $null) {
    if ($Inner -is [System.Windows.Forms.TextBox] -or $Inner -is [System.Windows.Forms.NumericUpDown]) {
        $Inner.BorderStyle = "None"
    }
    $Inner.Font = $(if ($Font) { $Font } else { [CoreUi.Theme]::Ui })
    $hidden = 0
    if ($Inner -is [System.Windows.Forms.NumericUpDown]) {
        $hidden = [Math]::Max(16, $Inner.Controls[0].Width) + 2
    }
    $f = New-Object CoreUi.FieldFrame
    $f.Location = New-Object System.Drawing.Point($X, $Y)
    $f.Size = New-Object System.Drawing.Size($W, $H)
    $f.Wrap($Inner, $hidden)
    return $f
}

function Initialize-UiForm($Form) {
    [CoreUi.Styler]::Form($Form)
}

function Show-UiMessage([string]$Text, [string]$Caption, [string]$Buttons = "OK", [string]$Icon = "Information") {
    return [CoreUi.MessageDialog]::Show($Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

# アプリのアイコン (32px)。枠の中を Windows の青と Edge Box の緑に分ける。
# デスクトップのアイコン (cpu-console.ps1 -Setup) と同じ濃い色の本体にする (画面の配色とは別)
function Get-UiAppIcon([string]$Style = "console") {
    try {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(17, 24, 32))
        $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(53, 67, 82))
        $win  = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Win)
        $vm   = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Edge)
        $g.FillRectangle($body, 2, 2, 28, 28)
        $g.DrawRectangle($edge, 2, 2, 27, 27)
        if ($Style -eq "monitor") {
            $g.FillRectangle($win, 8, 16, 4, 9); $g.FillRectangle($vm, 14, 9, 4, 16); $g.FillRectangle($win, 20, 19, 4, 6)
        } else {
            $g.FillRectangle($win, 8, 8, 7, 16); $g.FillRectangle($vm, 17, 8, 7, 16)
        }
        $g.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch { return $null }
}
