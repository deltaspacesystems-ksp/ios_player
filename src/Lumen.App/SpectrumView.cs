using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Lumen.App;

/// <summary>cava-style bars drawn with plain rectangles; <see cref="Update"/> is called at the configured fps.</summary>
public sealed class SpectrumView : UserControl
{
    private readonly Canvas _canvas = new();
    private Rectangle[] _bars = Array.Empty<Rectangle>();
    private Brush _fill = new SolidColorBrush(Microsoft.UI.Colors.White);

    public SpectrumView()
    {
        Content = _canvas;
        SizeChanged += (_, _) => Layout();
    }

    public Brush Fill { get => _fill; set { _fill = value; foreach (var b in _bars) b.Fill = value; } }

    public void Update(float[] values)
    {
        if (_bars.Length != values.Length) { Rebuild(values.Length); }
        double h = ActualHeight;
        for (int i = 0; i < _bars.Length; i++)
        {
            double bh = Math.Max(3, values[i] * h);
            _bars[i].Height = bh;
            Canvas.SetTop(_bars[i], h - bh);
        }
    }

    private void Rebuild(int count)
    {
        _canvas.Children.Clear();
        _bars = new Rectangle[count];
        for (int i = 0; i < count; i++)
        {
            _bars[i] = new Rectangle { RadiusX = 2, RadiusY = 2, Fill = _fill, Opacity = 0.9 };
            _canvas.Children.Add(_bars[i]);
        }
        Layout();
    }

    private void Layout()
    {
        if (_bars.Length == 0) return;
        double gap = 3, w = Math.Max(1, (ActualWidth - gap * (_bars.Length - 1)) / _bars.Length);
        for (int i = 0; i < _bars.Length; i++)
        {
            _bars[i].Width = w;
            Canvas.SetLeft(_bars[i], i * (w + gap));
        }
    }
}
