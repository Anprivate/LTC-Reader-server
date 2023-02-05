unit MainUnit;

interface

uses
  System.SysUtils, System.Variants, System.Classes, System.IniFiles,
  System.Types, System.StrUtils, System.DateUtils, System.IOutils,
  Winapi.Windows, Winapi.Messages, Winapi.ActiveX,
  Winapi.DirectShow9, Winapi.Direct3D9, Winapi.D3DX9,
  VCL.Graphics, VCL.Controls, VCL.Forms, VCL.Dialogs, VCL.StdCtrls,
  VCL.ExtCtrls, VCL.Mask,
  DeckLinkAPI, DeckLinkAPI.Discovery, DeckLinkAPI.Modes,
  audio_card_capture, decklink_capture, tc_decoder, wasapi_capture,
  UnitOneBuff, UnitOneText, UnitOneDevice;

const
  WM_DECODER1 = WM_USER + 3;
  WM_DECODER2 = WM_USER + 4;

type
  TIni_params = record
    DesiredDevice: string;
    SelectedDevice: string;
    SelectedDeviceNum: integer;
    DesiredChannel1: integer;
    DesiredChannel2: integer;
    SelectedChannel1: integer;
    SelectedChannel2: integer;
    EmulationEnabled: boolean;
    Correction: integer;
  end;

  TFormTCreader = class(TForm)
    Memo1: TMemo;
    PaintBoxWaveform: TPaintBox;
    Timer1: TTimer;
    PanelMain: TPanel;
    LabelDevice: TLabel;
    LabelChannel: TLabel;
    PanelTC1: TPanel;
    ComboBoxDevice: TComboBox;
    ComboBoxChannel1: TComboBox;
    ButtonStartStop: TButton;
    PanelRAW1: TPanel;
    PanelEmulation: TPanel;
    MaskEditTC: TMaskEdit;
    ButtonPreroll: TButton;
    ButtonEmuStartStop: TButton;
    PanelEmuTC: TPanel;
    PanelMain2: TPanel;
    Label2: TLabel;
    PanelTC2: TPanel;
    ComboBoxChannel2: TComboBox;
    PanelRAW2: TPanel;
    PanelDifference: TPanel;
    Label1: TLabel;
    ComboBoxControlMode: TComboBox;
    CheckBoxLock: TCheckBox;

    //
    procedure ComboBoxDeviceChange(Sender: TObject);
    procedure ComboBoxChannel1Change(Sender: TObject);
    procedure ButtonStartStopClick(Sender: TObject);
    procedure ButtonPrerollClick(Sender: TObject);
    procedure ButtonEmuStartStopClick(Sender: TObject);
    procedure ComboBoxChannel2Change(Sender: TObject);
    //
    procedure OnBMLockChange(var Msg: TMessage); message BMModeChangeMessage;
    procedure OnDecoder1(var Msg: TMessage); message WM_DECODER1;
    procedure OnDecoder2(var Msg: TMessage); message WM_DECODER2;
    procedure DecoderProcess(decnum: integer; param1: Int64; param2: Int64);
    //
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormResize(Sender: TObject);
    //
    procedure Timer1Timer(Sender: TObject);
    procedure ComboBoxControlModeChange(Sender: TObject);
    procedure CheckBoxLockClick(Sender: TObject);
  private
    Ini_params: TIni_params;
    isStarted: boolean;
    //
    frames_list1: TTLframes_list;
    frames_list2: TTLframes_list;
    log_list: TTLtext_list;
    //
    audio_card_capturer: Taudio_card_capturer;
    decklink_capturer: Tdecklink_capturer;
    wasapi_capturer: Twasapi_capturer;
    tc_decoder_thread1: TTC_decoder_thread;
    tc_decoder_thread2: TTC_decoder_thread;
    //
    MsgTCServer: Cardinal;
    emu_started: boolean;
    emu_offset_in_ms: Int64;
    emu_last_sent: TDateTime;
    emu_last_indicated: TDateTime;
    qpc_freq: Int64;
    last_rxed_tc: Int64;
    last_difference1, last_difference2: Int64;
    current_control_mode: integer;
    //
    procedure StartCapture;
    procedure StopCapture;
    //
    procedure intimerwaveform;
    procedure intimerlog;
    procedure intimerpanels;
    procedure intimeremu;
    //
    procedure AddToLog(instring: string);
    function TryStringToTC(instring: string; fps_num: Int64; fps_den: Int64;
      var TC: Int64): boolean;
    function TCtoString(inTC: Int64; fps_num: Int64; fps_den: Int64): string;
  public
  end;

  EMyOwnException = class(Exception);

type
  TTC = record
    Hours: byte;
    Minutes: byte;
    Seconds: byte;
    Frames: byte;
  end;

var
  FormTCreader: TFormTCreader;

implementation

{$R *.dfm}

procedure WriteToLog(chto: string);
var
  F1: TextFile;
  log_file_name: string;
begin
  log_file_name := extractfilepath(paramstr(0)) + 'process.log';
  if FileExists(log_file_name) then
  begin
    AssignFile(F1, log_file_name);
    Append(F1);
  end
  else
  begin
    AssignFile(F1, log_file_name);
    Rewrite(F1);
  end;
  Writeln(F1, chto);
  Flush(F1);
  CloseFile(F1);
end;

procedure TFormTCreader.FormCreate(Sender: TObject);
var
  ini: TIniFile;
  i: integer;
  tmpstr: string;
  BuildTime: TDateTime;
begin
  Memo1.Clear;

  BuildTime := TFile.GetLastWriteTime(paramstr(0));
  Self.Caption := 'TC Reader - server (build ' +
    FormatDateTime('yyyy-mm-dd hh:nn:ss', BuildTime) + ')';

  Self.DoubleBuffered := true;

  QueryPerformanceFrequency(qpc_freq);

  Ini_params.SelectedDeviceNum := -1;

  ini := TIniFile.Create(extractfilepath(paramstr(0)) + 'settings.ini');
  try
    tmpstr := ini.ReadString('device', 'name', '');
    Ini_params.DesiredDevice := StringReplace(tmpstr, '"', '', [rfReplaceAll]);
    Ini_params.DesiredChannel1 := ini.ReadInteger('device', 'channel1', 0);
    Ini_params.DesiredChannel2 := ini.ReadInteger('device', 'channel2', 0);
    Ini_params.Correction := ini.ReadInteger('device', 'correction', 0);
    Ini_params.SelectedDeviceNum := -1;

    Ini_params.EmulationEnabled := ini.ReadBool('emulation',
      'emulation_enabled', true);

    MaskEditTC.Text := ini.ReadString('emulation', 'timecode', '00:00:00:00');

    current_control_mode := ini.ReadInteger('emulation', 'mode', 0);
    ComboBoxControlMode.ItemIndex := current_control_mode;
    ComboBoxControlModeChange(Self);

    Self.Left := ini.ReadInteger('position', 'left', Self.Left);
    Self.Top := ini.ReadInteger('position', 'top', Self.Top);
    Self.Width := ini.ReadInteger('position', 'width', Self.Width);
    Self.Height := ini.ReadInteger('position', 'height', Self.Height);
  finally
    ini.Free;
  end;

  if Ini_params.EmulationEnabled then
  begin
    PanelEmulation.Visible := true;
    PanelEmulation.Enabled := true;
  end
  else
  begin
    PanelEmulation.Visible := false;
    PanelEmulation.Enabled := false;

  end;
  ComboBoxDevice.Clear;

  frames_list1 := TTLframes_list.Create;
  frames_list2 := TTLframes_list.Create;
  log_list := TTLtext_list.Create;

  {
    audio_card_capturer := Taudio_card_capturer.Create(Self);
    audio_card_capturer.out_frames1 := frames_list1;
    audio_card_capturer.out_frames2 := frames_list2;
    audio_card_capturer.OutputText := log_list;

    audio_card_capturer.AddDevices(ComboBoxDevice);
  }
  audio_card_capturer := nil;

  wasapi_capturer := Twasapi_capturer.Create(Self);
  wasapi_capturer.out_frames1 := frames_list1;
  wasapi_capturer.out_frames2 := frames_list2;
  wasapi_capturer.OutputText := log_list;

  wasapi_capturer.AddDevices(ComboBoxDevice);

  decklink_capturer := Tdecklink_capturer.Create(Self);
  decklink_capturer.out_frames1 := frames_list1;
  decklink_capturer.out_frames2 := frames_list2;
  decklink_capturer.OutputText := log_list;

  decklink_capturer.AddDevices(ComboBoxDevice);

  for i := 0 to ComboBoxDevice.Items.Count - 1 do
  begin
    if SameText(ComboBoxDevice.Items.Strings[i], Ini_params.DesiredDevice) then
    begin
      Ini_params.SelectedDeviceNum := i;
      Ini_params.SelectedDevice := ComboBoxDevice.Items.Strings[i];
    end;
  end;

  if Ini_params.SelectedDeviceNum >= 0 then
  begin
    ComboBoxDevice.ItemIndex := Ini_params.SelectedDeviceNum;
  end
  else
  begin
    if ComboBoxDevice.Items.Count > 0 then
      ComboBoxDevice.ItemIndex := 0;
  end;

  ComboBoxDeviceChange(Self);

  if Ini_params.SelectedDeviceNum >= 0 then
    ButtonStartStop.Enabled := true;

  tc_decoder_thread1 := TTC_decoder_thread.Create(true);
  tc_decoder_thread1.OutputText := log_list;
  tc_decoder_thread1.in_frames := frames_list1;
  tc_decoder_thread1.IDstring := 'DCD1: ';
  tc_decoder_thread1.MsgID := WM_DECODER1;
  tc_decoder_thread1.MainHandle := Self.Handle;
  tc_decoder_thread1.Start;

  tc_decoder_thread2 := TTC_decoder_thread.Create(true);
  tc_decoder_thread2.OutputText := log_list;
  tc_decoder_thread2.in_frames := frames_list2;
  tc_decoder_thread2.IDstring := 'DCD2: ';
  tc_decoder_thread2.MsgID := WM_DECODER2;
  tc_decoder_thread2.MainHandle := Self.Handle;
  tc_decoder_thread2.Start;

  with PaintBoxWaveform.Canvas do
  begin
    Brush.Color := clWhite;
    FillRect(ClipRect);
  end;

  MsgTCServer := RegisterWindowMessage('TimecodeServer');
  if MsgTCServer = 0 then
    WriteToLog('TC server not registered')
  else
    WriteToLog('TC server ID:' + inttohex(MsgTCServer));
end;

procedure TFormTCreader.FormClose(Sender: TObject; var Action: TCloseAction);
var
  ini: TIniFile;

  tmpfl: TLframes_list;
  tmpf: TOne_frame;
begin
  if isStarted then
  begin
    if Assigned(audio_card_capturer) then
      audio_card_capturer.Stop;
    if Assigned(decklink_capturer) and decklink_capturer.isStarted then
      decklink_capturer.Stop;
    if Assigned(wasapi_capturer) then
      wasapi_capturer.Stop;
  end;

  audio_card_capturer.Free;
  decklink_capturer.Free;

  if Assigned(tc_decoder_thread1) then
  begin
    tc_decoder_thread1.in_frames := nil;
    tc_decoder_thread1.OutputText := nil;
    tc_decoder_thread1.Terminate;
  end;

  if Assigned(tc_decoder_thread2) then
  begin
    tc_decoder_thread2.in_frames := nil;
    tc_decoder_thread2.OutputText := nil;
    tc_decoder_thread2.Terminate;
  end;

  if Assigned(frames_list1) then
  begin
    tmpfl := frames_list1.LockList;
    while tmpfl.Count > 0 do
    begin
      tmpf := tmpfl.Items[0];
      tmpfl.Delete(0);
      tmpf.Free;
    end;
    frames_list1.UnLockList;
    frames_list1.Free;
    frames_list1 := nil;
  end;

  if Assigned(frames_list2) then
  begin
    tmpfl := frames_list2.LockList;
    while tmpfl.Count > 0 do
    begin
      tmpf := tmpfl.Items[0];
      tmpfl.Delete(0);
      tmpf.Free;
    end;
    frames_list2.UnLockList;
    frames_list2.Free;
    frames_list2 := nil;
  end;

  ini := TIniFile.Create(extractfilepath(paramstr(0)) + 'settings.ini');
  try
    ini.WriteString('device', 'name', '"' + Ini_params.SelectedDevice + '"');
    ini.WriteInteger('device', 'channel1', Ini_params.SelectedChannel1);
    ini.WriteInteger('device', 'channel2', Ini_params.SelectedChannel2);

    ini.WriteBool('emulation', 'emulation_enabled',
      Ini_params.EmulationEnabled);
    ini.WriteString('emulation', 'timecode', MaskEditTC.Text);
    ini.WriteInteger('emulation', 'mode', current_control_mode);

    ini.WriteInteger('position', 'left', Self.Left);
    ini.WriteInteger('position', 'top', Self.Top);
    ini.WriteInteger('position', 'width', Self.Width);
    ini.WriteInteger('position', 'height', Self.Height);
  finally
    ini.Free;
  end;
end;

procedure TFormTCreader.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  //
end;

procedure TFormTCreader.FormResize(Sender: TObject);
var
  minWidth, minHeight: integer;
begin
  minWidth := ButtonStartStop.Left + ButtonStartStop.Width + 15 +
    PanelTC1.Width + 15;

  if Self.ClientWidth < minWidth then
    Self.ClientWidth := minWidth;

  PanelMain.Width := Self.ClientWidth - PanelMain.Left * 2;
  PanelMain2.Width := PanelMain.Width;

  PanelTC1.Left := PanelMain.Width - PanelTC1.Width - 15;
  PanelTC2.Left := PanelTC1.Left;
  PanelRAW1.Left := PanelTC1.Left;
  PanelRAW2.Left := PanelRAW1.Left;

  PanelEmulation.Width := PanelMain.Width;

  PaintBoxWaveform.Width := Self.ClientWidth - PaintBoxWaveform.Left * 2;
  Memo1.Width := PaintBoxWaveform.Width;

  minHeight := PaintBoxWaveform.Top + 100 + PaintBoxWaveform.Left + 100 +
    PaintBoxWaveform.Left;

  if Self.ClientHeight < minHeight then
    Self.ClientHeight := minHeight;

  PaintBoxWaveform.Height := (Self.ClientHeight - PaintBoxWaveform.Top - 2 *
    PaintBoxWaveform.Left) div 2;

  Memo1.Top := PaintBoxWaveform.Top + PaintBoxWaveform.Height +
    PaintBoxWaveform.Left;
  Memo1.Height := PaintBoxWaveform.Height;
end;

procedure TFormTCreader.AddToLog(instring: string);
begin
  if not Assigned(log_list) then
    Exit;

  log_list.Add(TOne_text.Create('Main: ' + instring));
end;

procedure TFormTCreader.ButtonEmuStartStopClick(Sender: TObject);
var
  tmptc: Int64;
  qpc: Int64;
  qpc_start_in_ms: Int64;
  emu_tc_start_in_ms: Int64;
begin
  if emu_started then
  begin
    if MsgTCServer <> 0 then
    begin
      PostMessage(HWND_BROADCAST, MsgTCServer, 3, 0);
      Memo1.Lines.Add('Stop message sent');
    end;
    emu_started := false;
    ButtonEmuStartStop.Caption := 'Start';
    ButtonPreroll.Enabled := true;
  end
  else
  begin
    if TryStringToTC(MaskEditTC.Text, 25, 1, tmptc) then
    begin
      emu_tc_start_in_ms := tmptc * 1000 div 25;

      QueryPerformanceCounter(qpc);

      qpc_start_in_ms := qpc div (qpc_freq div 1000);

      emu_offset_in_ms := qpc_start_in_ms - emu_tc_start_in_ms;

      if MsgTCServer <> 0 then
      begin
        PostMessage(HWND_BROADCAST, MsgTCServer, 2, emu_offset_in_ms);

        Memo1.Lines.Add('Start message sent');
      end;
      emu_last_sent := Now();
      emu_last_indicated := 0;

      emu_started := true;
      ButtonEmuStartStop.Caption := 'Stop';
      ButtonPreroll.Enabled := false;
    end;
  end;
end;

procedure TFormTCreader.ButtonPrerollClick(Sender: TObject);
var
  tmptc: Int64;
begin
  if not emu_started and (MsgTCServer <> 0) then
  begin
    if TryStringToTC(MaskEditTC.Text, 25, 1, tmptc) then
    begin
      PostMessage(HWND_BROADCAST, MsgTCServer, 1, tmptc * 40);
      Memo1.Lines.Add('Preroll message sent');
    end;
  end;
end;

procedure TFormTCreader.ButtonStartStopClick(Sender: TObject);
begin
  if isStarted then
    StopCapture
  else
    StartCapture;
end;

procedure TFormTCreader.StartCapture;
var
  in_device: TOneDevice;
  subStarted: boolean;
begin
  in_device := ComboBoxDevice.Items.Objects[ComboBoxDevice.ItemIndex]
    as TOneDevice;

  subStarted := false;

  if in_device.isDecklink and Assigned(decklink_capturer) then
  begin
    decklink_capturer.UseChannel1 := Ini_params.SelectedChannel1;
    decklink_capturer.UseChannel2 := Ini_params.SelectedChannel2;
    decklink_capturer.Start(in_device.dl_card);
    subStarted := decklink_capturer.isStarted;
  end;

  if in_device.isOldAudio and Assigned(audio_card_capturer) then
  begin
    audio_card_capturer.SelectedDevice := in_device.DevNo;
    audio_card_capturer.UseChannel1 := Ini_params.SelectedChannel1;
    audio_card_capturer.UseChannel2 := Ini_params.SelectedChannel2;
    audio_card_capturer.Start;
    subStarted := true;
  end;

  if in_device.isWasapi and Assigned(wasapi_capturer) then
  begin
    wasapi_capturer.UseChannel1 := Ini_params.SelectedChannel1;
    wasapi_capturer.UseChannel2 := Ini_params.SelectedChannel2;
    wasapi_capturer.Start(in_device.wasapi_device_id);
    subStarted := true;
  end;

  if subStarted then
  begin
    ComboBoxDevice.Enabled := false;
    ButtonStartStop.Caption := 'Stop';
    isStarted := true;
  end;
end;

procedure TFormTCreader.StopCapture;
begin
  if Assigned(audio_card_capturer) then
    audio_card_capturer.Stop;

  if Assigned(decklink_capturer) then
    decklink_capturer.Stop;

  if Assigned(wasapi_capturer) then
    wasapi_capturer.Stop;

  ComboBoxDevice.Enabled := true;

  ButtonStartStop.Caption := 'Start';
  isStarted := false;
  //
end;

procedure TFormTCreader.CheckBoxLockClick(Sender: TObject);
begin
  ComboBoxControlMode.Enabled := not CheckBoxLock.Checked;
  ButtonStartStop.Enabled := not CheckBoxLock.Checked;
  ComboBoxChannel1.Enabled := not CheckBoxLock.Checked;
  ComboBoxChannel2.Enabled := not CheckBoxLock.Checked;
  ButtonPreroll.Enabled := not CheckBoxLock.Checked;
end;

procedure TFormTCreader.ComboBoxChannel1Change(Sender: TObject);
begin
  Ini_params.SelectedChannel1 := ComboBoxChannel1.ItemIndex;
  Ini_params.DesiredChannel1 := ComboBoxChannel1.ItemIndex;

  if Assigned(audio_card_capturer) then
    audio_card_capturer.UseChannel1 := ComboBoxChannel1.ItemIndex;

  if Assigned(decklink_capturer) then
    decklink_capturer.UseChannel1 := ComboBoxChannel1.ItemIndex;

  if Assigned(wasapi_capturer) then
    wasapi_capturer.SetChannels(ComboBoxChannel1.ItemIndex,
      ComboBoxChannel2.ItemIndex);
end;

procedure TFormTCreader.ComboBoxChannel2Change(Sender: TObject);
begin
  Ini_params.SelectedChannel2 := ComboBoxChannel2.ItemIndex;
  Ini_params.DesiredChannel2 := ComboBoxChannel2.ItemIndex;

  if Assigned(audio_card_capturer) then
    audio_card_capturer.UseChannel2 := ComboBoxChannel2.ItemIndex;

  if Assigned(decklink_capturer) then
    decklink_capturer.UseChannel2 := ComboBoxChannel2.ItemIndex;

  if Assigned(wasapi_capturer) then
    wasapi_capturer.SetChannels(ComboBoxChannel1.ItemIndex,
      ComboBoxChannel2.ItemIndex);
end;

procedure TFormTCreader.ComboBoxControlModeChange(Sender: TObject);
begin
  current_control_mode := ComboBoxControlMode.ItemIndex;
  ButtonEmuStartStop.Enabled := current_control_mode = 3;

  if current_control_mode <> 3 then
    emu_started := false;
end;

procedure TFormTCreader.ComboBoxDeviceChange(Sender: TObject);
var
  i: integer;
begin
  if ComboBoxDevice.ItemIndex < 0 then
    Exit;

  Ini_params.SelectedDeviceNum := ComboBoxDevice.ItemIndex;
  Ini_params.SelectedDevice := ComboBoxDevice.Items.Strings
    [ComboBoxDevice.ItemIndex];

  ComboBoxChannel1.Clear;
  for i := 1 to (ComboBoxDevice.Items.Objects[ComboBoxDevice.ItemIndex]
    as TOneDevice).Channels do
    ComboBoxChannel1.Items.Add(inttostr(i));

  if (Ini_params.DesiredChannel1 >= 0) and
    (Ini_params.DesiredChannel1 < ComboBoxChannel1.Items.Count) then
    ComboBoxChannel1.ItemIndex := Ini_params.DesiredChannel1
  else
    ComboBoxChannel1.ItemIndex := 0;
  Ini_params.SelectedChannel1 := ComboBoxChannel1.ItemIndex;

  ComboBoxChannel2.Clear;
  for i := 1 to (ComboBoxDevice.Items.Objects[ComboBoxDevice.ItemIndex]
    as TOneDevice).Channels do
    ComboBoxChannel2.Items.Add(inttostr(i));

  if (Ini_params.DesiredChannel2 >= 0) and
    (Ini_params.DesiredChannel2 < ComboBoxChannel2.Items.Count) then
    ComboBoxChannel2.ItemIndex := Ini_params.DesiredChannel2
  else
    ComboBoxChannel2.ItemIndex := 0;
  Ini_params.SelectedChannel2 := ComboBoxChannel2.ItemIndex;
end;

procedure TFormTCreader.Timer1Timer(Sender: TObject);
begin
  intimerlog;
  intimerpanels;
  intimerwaveform;
  intimeremu;
end;

procedure TFormTCreader.intimeremu;
var
  qpc, qpc_in_ms, eTC: Int64;
begin
  if not emu_started then
    Exit;

  if MillisecondsBetween(emu_last_sent, Now()) > 500 then
  begin
    if MsgTCServer <> 0 then
      PostMessage(HWND_BROADCAST, MsgTCServer, 2, emu_offset_in_ms);
    emu_last_sent := Now();
  end;

  if MillisecondsBetween(emu_last_indicated, Now()) > 100 then
  begin
    QueryPerformanceCounter(qpc);

    qpc_in_ms := qpc div (qpc_freq div 1000);

    eTC := (qpc_in_ms - emu_offset_in_ms) div 40;
    PanelEmuTC.Caption := TCtoString(eTC, 25, 1);

    emu_last_indicated := Now();
  end;

end;

procedure TFormTCreader.intimerlog;
var
  tmp_log_list: TLtext_list;
  tmp_msg: TOne_text;
begin
  if Assigned(log_list) then
  begin
    tmp_log_list := log_list.LockList;
    while tmp_log_list.Count > 0 do
    begin
      tmp_msg := tmp_log_list.Items[0];
      tmp_log_list.Delete(0);
      Memo1.Lines.Add(tmp_msg.Text);
      tmp_msg.Free;
    end;
    log_list.UnLockList;
  end;
end;

procedure TFormTCreader.intimerpanels;
var
  TC: TTC;
  tmp_diff, abs_diff, fr_diff, ms_diff: Int64;
begin
  if Assigned(tc_decoder_thread1) then
  begin
    with tc_decoder_thread1 do
      if TCisReady then
      begin
        PanelRAW1.Caption := format('%4.4x %4.4x %4.4x %4.4x',
          [TCrawdata[3], TCrawdata[2], TCrawdata[1], TCrawdata[0]]);
        TC.Hours := (TCrawdata[3] and $000F) + 10 *
          ((TCrawdata[3] and $0300) shr 8);
        TC.Minutes := (TCrawdata[2] and $000F) + 10 *
          ((TCrawdata[2] and $0700) shr 8);
        TC.Seconds := (TCrawdata[1] and $000F) + 10 *
          ((TCrawdata[1] and $0700) shr 8);
        TC.Frames := (TCrawdata[0] and $000F) + 10 *
          ((TCrawdata[0] and $0300) shr 8);
        PanelTC1.Caption := format('%2.2d:%2.2d:%2.2d:%2.2d',
          [TC.Hours, TC.Minutes, TC.Seconds, TC.Frames]);
        last_rxed_tc := TC.Frames + 25 *
          (TC.Seconds + 60 * (TC.Minutes + 60 * TC.Hours));

        last_difference1 := TCdifference;
        TCisReady := false;
      end;
  end;

  if Assigned(tc_decoder_thread2) then
  begin
    with tc_decoder_thread2 do
      if TCisReady then
      begin
        PanelRAW2.Caption := format('%4.4x %4.4x %4.4x %4.4x',
          [TCrawdata[3], TCrawdata[2], TCrawdata[1], TCrawdata[0]]);
        TC.Hours := (TCrawdata[3] and $000F) + 10 *
          ((TCrawdata[3] and $0300) shr 8);
        TC.Minutes := (TCrawdata[2] and $000F) + 10 *
          ((TCrawdata[2] and $0700) shr 8);
        TC.Seconds := (TCrawdata[1] and $000F) + 10 *
          ((TCrawdata[1] and $0700) shr 8);
        TC.Frames := (TCrawdata[0] and $000F) + 10 *
          ((TCrawdata[0] and $0300) shr 8);
        PanelTC2.Caption := format('%2.2d:%2.2d:%2.2d:%2.2d',
          [TC.Hours, TC.Minutes, TC.Seconds, TC.Frames]);

        last_difference2 := TCdifference;
        TCisReady := false;
      end;
  end;

  tmp_diff := last_difference1 - last_difference2;
  abs_diff := Abs(tmp_diff);

  fr_diff := abs_diff div 40;
  ms_diff := abs_diff mod 40;

  if abs_diff > 40000000 then
    PanelDifference.Caption := '---'
  else
  begin
    if tmp_diff >= 0 then
      PanelDifference.Caption := format('%d fr %d ms', [fr_diff, ms_diff])
    else
      PanelDifference.Caption := format('-%d fr %d ms', [fr_diff, ms_diff]);
  end;
end;

procedure TFormTCreader.intimerwaveform;
type
  TPointArr = array [0 .. 16383] of TPoint;
  PPointArr = ^TPointArr;
var
  XScale, YScale: single;
  Middle: single;
  i: integer;
  points: PPointArr;
  tmp_frame: TOne_frame;
  thr_no: integer;

begin
  if not Assigned(tc_decoder_thread1.AudioData) or
    not Assigned(tc_decoder_thread2.AudioData) then
    Exit;

  PaintBoxWaveform.Canvas.Brush.Color := clWhite;

  PaintBoxWaveform.Canvas.FillRect(PaintBoxWaveform.Canvas.ClipRect);

  for thr_no := 1 to 2 do
  begin
    if thr_no = 1 then
      tmp_frame := tc_decoder_thread1.AudioData
    else
      tmp_frame := tc_decoder_thread2.AudioData;

    GetMem(points, tmp_frame.samples * SizeOf(TPoint));

    XScale := PaintBoxWaveform.Width / tmp_frame.samples;
    YScale := PaintBoxWaveform.Height / (1 shl 17);
    Middle := (thr_no * 2 - 1) * PaintBoxWaveform.Height / 4;

    for i := 0 to tmp_frame.samples - 1 do
      points^[i] := Point(round(i * XScale),
        round(Middle - tmp_frame.data^[i] * YScale));

    PaintBoxWaveform.Canvas.Polyline(Slice(points^, tmp_frame.samples));

    FreeMem(points);

    tmp_frame.Free;

    if thr_no = 1 then
      tc_decoder_thread1.AudioData := nil
    else
      tc_decoder_thread2.AudioData := nil;
  end;
end;

procedure TFormTCreader.OnBMLockChange(var Msg: TMessage);
begin
  decklink_capturer.OnModeChange;
end;

procedure TFormTCreader.OnDecoder1(var Msg: TMessage);
begin
  DecoderProcess(1, Msg.WParam, Msg.LParam);
end;

procedure TFormTCreader.OnDecoder2(var Msg: TMessage);
begin
  DecoderProcess(2, Msg.WParam, Msg.LParam);
end;

procedure TFormTCreader.DecoderProcess(decnum: integer; param1, param2: Int64);
var
  qpc, qpc_in_ms, eTC: Int64;
begin
  if (MsgTCServer <> 0) and (decnum = current_control_mode) then
  begin
    if CheckBoxLock.Checked and (param1 = 3) then
      AddToLog('Stop is disabled in ON AIR lock mode')
    else
    begin
      if param1 = 2 then
        PostMessage(HWND_BROADCAST, MsgTCServer, param1,
          param2 + Ini_params.Correction)
      else
        PostMessage(HWND_BROADCAST, MsgTCServer, param1, param2);
    end;

    // AddToLog(format('%d %d %d', [decnum, param1, param2]));

    if param1 = 2 then
    begin
      QueryPerformanceCounter(qpc);

      qpc_in_ms := qpc div (qpc_freq div 1000);

      eTC := (qpc_in_ms - param2) div 40;
      PanelEmuTC.Caption := TCtoString(eTC, 25, 1);
    end;
  end;
end;

function TFormTCreader.TCtoString(inTC, fps_num, fps_den: Int64): string;
var
  fullsec, iHours, iMinutes, iSeconds, iFrames, tmp: Int64;
begin
  fullsec := inTC * fps_den div fps_num;
  iFrames := inTC - (fullsec * fps_num div fps_den);

  tmp := fullsec;
  iHours := tmp div 3600;
  tmp := tmp mod 3600;

  iMinutes := tmp div 60;
  iSeconds := tmp mod 60;
  TCtoString := format('%.2u', [iHours]) + ':' + format('%.2u', [iMinutes]) +
    ':' + format('%.2u', [iSeconds]) + ':' + format('%.2u', [iFrames]);
end;

function TFormTCreader.TryStringToTC(instring: string; fps_num: Int64;
  fps_den: Int64; var TC: Int64): boolean;
var
  tmpstr: string;
  iHours, iMin, iSec, iFrames, fullseconds: Int64;
  Position: integer;
begin
  iHours := 0;
  iMin := 0;
  iSec := 0;

  tmpstr := ReverseString(instring);
  Position := pos(':', tmpstr);
  if Position > 0 then
  begin
    if not trystrtoint64(ReverseString(LeftStr(tmpstr, Position - 1)), iFrames)
    then
      iFrames := -1;
    tmpstr := MidStr(tmpstr, Position + 1, 1000);

    Position := pos(':', tmpstr);
    if Position > 0 then
    begin
      if not trystrtoint64(ReverseString(LeftStr(tmpstr, Position - 1)), iSec)
      then
        iSec := -1;
      tmpstr := MidStr(tmpstr, Position + 1, 1000);

      Position := pos(':', tmpstr);
      if Position > 0 then
      begin
        if not trystrtoint64(ReverseString(LeftStr(tmpstr, Position - 1)), iMin)
        then
          iMin := -1;
        tmpstr := MidStr(tmpstr, Position + 1, 1000);
        if not trystrtoint64(ReverseString(tmpstr), iHours) then
          iHours := -1;
      end
      else if not trystrtoint64(ReverseString(tmpstr), iMin) then
        iMin := -1;
    end
    else if not trystrtoint64(ReverseString(tmpstr), iSec) then
      iSec := -1;
  end
  else if not trystrtoint64(ReverseString(tmpstr), iFrames) then
    iFrames := -1;

  fullseconds := iSec + 60 * (iMin + 60 * iHours);
  TC := iFrames + (fullseconds * fps_num div fps_den);
  TryStringToTC := (iFrames >= 0) and (iSec >= 0) and (iMin >= 0) and
    (iHours >= 0);
end;

end.
