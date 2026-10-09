#Requires -Version 5.0
<#
  Mede o overlay de atalho (a seta, ou o que estiver no lugar dela) do jeito
  que o Explorer o recebe do cache de icones. NAO e servido pelo site e nao
  muda nada na maquina: so le.

      powershell -NoProfile -ExecutionPolicy Bypass -File tools\diagnostico-overlay.ps1

  Rode como o usuario que esta vendo o problema, SEM elevar: o cache de
  icones e por usuario, e um processo elevado com outra conta leria o cache
  errado.

  Como funciona: FileIconInit(TRUE) monta a lista de imagens do sistema a
  partir do cache gravado em disco -- o mesmo caminho do Explorer no boot --
  e o overlay 2 dessa lista e o de atalho. Para cada tamanho, conta os
  pixels que o Windows desenharia: os de alfa >= 16 quando a imagem tem
  canal alfa, ou os de mascara opaca quando nao tem. Foi com isto que se
  achou o quadrado preto: alfa 0 em todo pixel + mascara opaca.
#>

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ArrowRemove {
  [ComImport, Guid("46EB5926-582E-4017-9FDF-E8998DAA0950"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IImageList {
    [PreserveSig] int Add(IntPtr a, IntPtr b, ref int c);
    [PreserveSig] int ReplaceIcon(int i, IntPtr h, ref int c);
    [PreserveSig] int SetOverlayImage(int a, int b);
    [PreserveSig] int Replace(int i, IntPtr a, IntPtr b);
    [PreserveSig] int AddMasked(IntPtr a, int b, ref int c);
    [PreserveSig] int Draw(IntPtr p);
    [PreserveSig] int Remove(int i);
    [PreserveSig] int GetIcon(int i, int flags, ref IntPtr picon);
    [PreserveSig] int GetImageInfo(int i, IntPtr p);
    [PreserveSig] int Copy(int a, IntPtr b, int c, int d);
    [PreserveSig] int Merge(int a, IntPtr b, int c, int d, int e, ref Guid f, ref IntPtr g);
    [PreserveSig] int Clone(ref Guid a, ref IntPtr b);
    [PreserveSig] int GetImageRect(int i, IntPtr p);
    [PreserveSig] int GetIconSize(ref int cx, ref int cy);
    [PreserveSig] int SetIconSize(int cx, int cy);
    [PreserveSig] int GetImageCount(ref int pi);
    [PreserveSig] int SetImageCount(int n);
    [PreserveSig] int SetBkColor(int a, ref int b);
    [PreserveSig] int GetBkColor(ref int a);
    [PreserveSig] int BeginDrag(int a, int b, int c);
    [PreserveSig] int EndDrag();
    [PreserveSig] int DragEnter(IntPtr a, int b, int c);
    [PreserveSig] int DragLeave(IntPtr a);
    [PreserveSig] int DragMove(int a, int b);
    [PreserveSig] int SetDragCursorImage(IntPtr a, int b, int c, int d);
    [PreserveSig] int DragShowNolock(int a);
    [PreserveSig] int GetDragImage(IntPtr a, IntPtr b, ref Guid c, ref IntPtr d);
    [PreserveSig] int GetItemFlags(int i, ref int f);
    [PreserveSig] int GetOverlayImage(int iOverlay, ref int piIndex);
  }
  [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int x; public int y; public IntPtr hbmMask; public IntPtr hbmColor; }
  [StructLayout(LayoutKind.Sequential)] public struct BITMAP { public int bmType; public int bmWidth; public int bmHeight; public int bmWidthBytes; public ushort bmPlanes; public ushort bmBitsPixel; public IntPtr bmBits; }
  [StructLayout(LayoutKind.Sequential)] public struct BIH { public int biSize; public int biWidth; public int biHeight; public short biPlanes; public short biBitCount; public int biCompression; public int biSizeImage; public int a; public int b; public int c; public int d; }
  public static class Overlay {
    [DllImport("shell32.dll", EntryPoint="#727")] static extern int SHGetImageList(int iImageList, ref Guid riid, out IImageList ppv);
    [DllImport("shell32.dll", EntryPoint="#660")] public static extern bool FileIconInit(bool restore);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int c, out BITMAP bm);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bm, uint s, uint n, byte[] bits, ref BIH bi, uint u);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr w);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr w, IntPtr dc);

    static byte[] Bits(IntPtr hbm, int w, int h) {
      var bi = new BIH(); bi.biSize = Marshal.SizeOf(typeof(BIH)); bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32;
      var px = new byte[w * h * 4]; IntPtr dc = GetDC(IntPtr.Zero);
      try { GetDIBits(dc, hbm, 0, (uint)h, px, ref bi, 0); } finally { ReleaseDC(IntPtr.Zero, dc); }
      return px;
    }

    // Devolve { pixels visiveis, total, maior alfa, mascara opaca } do overlay
    // de atalho na lista de imagens do sistema 'shil'.
    public static int[] Measure(int shil) {
      Guid iid = new Guid("46EB5926-582E-4017-9FDF-E8998DAA0950"); IImageList il;
      if (SHGetImageList(shil, ref iid, out il) != 0 || il == null) return null;
      int img = -1; if (il.GetOverlayImage(2, ref img) != 0 || img < 0) return null;
      IntPtr hi = IntPtr.Zero; if (il.GetIcon(img, 1, ref hi) != 0 || hi == IntPtr.Zero) return null;
      ICONINFO ii; GetIconInfo(hi, out ii); DestroyIcon(hi);
      try {
        BITMAP bm; GetObject(ii.hbmColor, Marshal.SizeOf(typeof(BITMAP)), out bm);
        int w = bm.bmWidth, h = bm.bmHeight, n = w * h;
        byte[] c = Bits(ii.hbmColor, w, h), m = Bits(ii.hbmMask, w, h);
        int maxA = 0, forte = 0, opaca = 0;
        for (int p = 0; p < n; p++) {
          int a = c[p*4+3]; if (a > maxA) maxA = a; if (a >= 16) forte++;
          if (m[p*4] == 0 && m[p*4+1] == 0 && m[p*4+2] == 0) opaca++;
        }
        return new[] { maxA > 0 ? forte : opaca, n, maxA, opaca };
      } finally { DeleteObject(ii.hbmColor); DeleteObject(ii.hbmMask); }
    }
  }
}
'@

[ArrowRemove.Overlay]::FileIconInit($true) | Out-Null

$quebrado = $false
foreach ($lista in @(@(1, 16), @(0, 32), @(2, 48), @(4, 256))) {
    $r = [ArrowRemove.Overlay]::Measure($lista[0])
    if (-not $r) {
        Write-Host ("{0,3}px: overlay de atalho nao encontrado" -f $lista[1]) -ForegroundColor Yellow
        continue
    }
    $estado = if ($r[0] -eq 0) { 'invisivel' } else { $quebrado = $true; 'VISIVEL' }
    Write-Host ("{0,3}px: {1} -- {2} de {3} pixels visiveis (alfa maximo {4}, mascara opaca em {5})" -f `
        $lista[1], $estado, $r[0], $r[1], $r[2], $r[3])
}

$valor = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' `
    -Name 29 -ErrorAction SilentlyContinue).'29'
Write-Host "HKLM Shell Icons\29: $(if ($valor) { $valor } else { '(sem valor -- seta padrao)' })"

if ($quebrado) {
    Write-Host 'Diagnostico: o overlay de atalho aparece (seta ou quadrado preto).' -ForegroundColor Red
} else {
    Write-Host 'Diagnostico: overlay de atalho invisivel em todos os tamanhos.' -ForegroundColor Green
}
