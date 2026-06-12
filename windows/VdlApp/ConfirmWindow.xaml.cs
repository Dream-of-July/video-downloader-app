using System.Windows;

namespace Vdl.App;

/// <summary>
/// 通用确认对话框：可自定义按钮文字（系统 MessageBox 做不到中文按钮文案）。
/// 取消侧是默认与 Esc 键，破坏性的确认动作用红字次按钮，防误触。
/// </summary>
public partial class ConfirmWindow : Window
{
    private ConfirmWindow(string message, string? detail, string confirmText, string cancelText)
    {
        InitializeComponent();
        MessageText.Text = message;
        if (string.IsNullOrEmpty(detail))
        {
            DetailText.Visibility = Visibility.Collapsed;
        }
        else
        {
            DetailText.Text = detail;
        }
        ConfirmButton.Content = confirmText;
        CancelButton.Content = cancelText;
    }

    /// <summary>弹出确认框，用户点确认（破坏性动作）返回 true。cancelText 缺省用本地化「取消」。</summary>
    public static bool Show(
        Window owner, string message, string? detail, string confirmText, string? cancelText = null)
    {
        var window = new ConfirmWindow(message, detail, confirmText, cancelText ?? Loc.S("L.Common.Cancel"))
        {
            Owner = owner,
        };
        return window.ShowDialog() == true;
    }

    private void OnConfirmClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }
}
