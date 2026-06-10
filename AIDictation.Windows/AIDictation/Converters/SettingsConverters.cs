using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace AIDictation.Converters;

/// <summary>
/// Compares value with parameter and returns true if equal.
/// </summary>
public class EqualityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value == null || parameter == null) return false;

        if (parameter is string paramStr && int.TryParse(paramStr, out int paramInt))
        {
            return value is int intValue && intValue == paramInt;
        }

        return value.Equals(parameter);
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is bool b && b && parameter is string paramStr && int.TryParse(paramStr, out int paramInt))
        {
            return paramInt;
        }
        return DependencyProperty.UnsetValue;
    }
}

/// <summary>
/// Compares value with parameter and returns Visibility.Visible if equal, Collapsed otherwise.
/// </summary>
public class EqualityToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value == null || parameter == null) return Visibility.Collapsed;

        if (parameter is string paramStr && int.TryParse(paramStr, out int paramInt))
        {
            return value is int intValue && intValue == paramInt ? Visibility.Visible : Visibility.Collapsed;
        }

        return value.Equals(parameter) ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}

/// <summary>
/// Converts boolean to brush (selected state styling).
/// True = PrimaryBrush, False = SurfaceBrush
/// </summary>
public class BoolToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is bool isSelected && isSelected)
        {
            return Application.Current.Resources["PrimaryBrush"] as SolidColorBrush ?? Brushes.Purple;
        }
        return Application.Current.Resources["SurfaceBrush"] as SolidColorBrush ?? Brushes.DarkGray;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}

/// <summary>
/// Inverts a boolean. Supports two-way binding for paired radio buttons.
/// </summary>
public class InverseBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        return value is bool b ? !b : value;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        return value is bool b ? !b : value;
    }
}

/// <summary>
/// Converts null/non-null to Visibility. Non-null = Visible, Null = Collapsed.
/// </summary>
public class NullToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is string str)
        {
            return string.IsNullOrEmpty(str) ? Visibility.Collapsed : Visibility.Visible;
        }
        return value != null ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}
