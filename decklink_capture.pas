unit decklink_capture;

interface

uses
  System.Classes, System.Types, System.SysUtils, System.DateUtils,
  System.Generics.Collections,
  VCL.StdCtrls, VCL.Forms,
  WinAPI.Windows, WinAPI.Messages, WinAPI.ActiveX, WinAPI.DirectShow9,
  DeckLinkAPI, DeckLinkAPI.Discovery, DeckLinkAPI.Modes,
  UnitOneBuff, UnitOneText, UnitOneDevice;

const
  BMModeChangeMessage = WM_USER + 1;

type
  Tdecklink_capturer = class(TComponent, IDeckLinkInputCallback)
  private
    l_Decklink: IDecklink;
    l_deckLinkInput: IDeckLinkInput;
    l_deckLinkStatus: IDeckLinkStatus;
    l_modeList: TList<IDeckLinkDisplayMode>;
    lastDetectedMode: IDeckLinkDisplayMode;
    MaxAudioChannels: Int64;
    ts_frequency: Int64;

    procedure AddToLog(instring: string);
    function ModeFromNumber(in_number: TOleEnum): IDeckLinkDisplayMode;
    procedure CheckAndRaiseIfFailed(hr: HResult; ErrorString: string);
  public
    OutputText: TTLtext_list;
    UseChannel1, UseChannel2: integer;
    //
    out_frames1, out_frames2: TTLframes_list;
    isStarted: boolean;
    //
    procedure Start(selected_card: IDecklink);
    procedure Stop;
    procedure OnModeChange;
    function AddDevices(tmp_cb: TComboBox): boolean;

    //
    function VideoInputFormatChanged(notificationEvents
      : _BMDVideoInputFormatChangedEvents;
      const newDisplayMode: IDeckLinkDisplayMode;
      detectedSignalFlags: _BMDDetectedVideoInputFormatFlags): HResult; stdcall;
    function VideoInputFrameArrived(const videoFrame: IDeckLinkVideoInputFrame;
      const audioPacket: IDeckLinkAudioInputPacket): HResult; stdcall;
  end;

  EMyOwnException = class(Exception);

implementation

{ Tdecklink_capturer }

function Tdecklink_capturer.AddDevices(tmp_cb: TComboBox): boolean;
var
  in_device: TOneDevice;
  //
  DeckLinkIterator: IDeckLinkIterator;
  tmp_Decklink: IDecklink;
  tmp_Decklink_name: WideString;
  tmp_Decklink_attributes: IDeckLinkAttributes;
  value_64: Int64;
  hr: HResult;
begin
  Result := false;
  try
    hr := CoCreateInstance(CLASS_CDeckLinkIterator, nil, CLSCTX_ALL,
      IID_IDeckLinkIterator, DeckLinkIterator);
    if not SUCCEEDED(hr) then
      raise EMyOwnException.Create('No Decklink card installed ' +
        SysErrorMessage(GetLastError()));

    // iterate Decklink devices
    while DeckLinkIterator.Next(tmp_Decklink) = S_OK do
    begin
      if not Assigned(tmp_Decklink) then
        Continue;

      if FAILED(tmp_Decklink.GetDisplayName(tmp_Decklink_name)) then
        Continue;

      if FAILED(tmp_Decklink.QueryInterface(IID_IDeckLinkAttributes,
        tmp_Decklink_attributes)) then
        Continue;

      if tmp_Decklink_attributes.GetInt(BMDDeckLinkVideoIOSupport, value_64) <> S_OK
      then
        Continue;

      if (value_64 and bmdDeviceSupportsCapture) = 0 then
        Continue;

      CheckAndRaiseIfFailed(tmp_Decklink_attributes.GetInt
        (BMDDeckLinkMaximumAudioChannels, value_64),
        'Get status BMDDeckLinkMaximumAudioChannels failed');

      in_device := TOneDevice.Create;
      in_device.isDecklink := true;
      in_device.Name := 'DL: ' + tmp_Decklink_name;
      in_device.DevNo := 0;
      in_device.Channels := value_64;
      in_device.dl_card := tmp_Decklink;

      tmp_cb.AddItem(in_device.Name, in_device);
    end;
    Result := true;
  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
  end;
end;

procedure Tdecklink_capturer.Start(selected_card: IDecklink);
var
  deckLinkAttributes: IDeckLinkAttributes;
  value: integer;
  value_64: Int64;

  displayModeIterator: IDeckLinkDisplayModeIterator;
  displayMode: IDeckLinkDisplayMode;
  BMDDisplayMode: _BMDDisplayMode;
  videoInputFlags: _BMDVideoInputFlags;
  displayName: WideString;
begin
  QueryPerformanceFrequency(ts_frequency);
  //
  try
    isStarted := false;

    l_Decklink := selected_card;

    if not Assigned(l_Decklink) then
      raise EMyOwnException.Create('No decklink card selected');

    CheckAndRaiseIfFailed(l_Decklink.QueryInterface(IID_IDeckLinkInput,
      l_deckLinkInput), 'Could not obtain the IDeckLinkInput interface');

    CheckAndRaiseIfFailed(l_Decklink.QueryInterface(IID_IDeckLinkStatus,
      l_deckLinkStatus), 'Could not obtain the IDeckLinkStatus interface');

    CheckAndRaiseIfFailed(l_Decklink.QueryInterface(IID_IDeckLinkAttributes,
      deckLinkAttributes),
      'Could not obtain the IDeckLinkAttributes interface');

    CheckAndRaiseIfFailed(deckLinkAttributes.GetFlag
      (BMDDeckLinkSupportsInputFormatDetection, value),
      'Get status BMDDeckLinkSupportsInputFormatDetection failed');

    if not boolean(value) then
      raise EMyOwnException.Create('Automatic mode detection is not supported');

    CheckAndRaiseIfFailed(deckLinkAttributes.GetInt
      (BMDDeckLinkMaximumAudioChannels, MaxAudioChannels),
      'Get status BMDDeckLinkMaximumAudioChannels failed');

    l_modeList := TList<IDeckLinkDisplayMode>.Create;
    CheckAndRaiseIfFailed(l_deckLinkInput.GetDisplayModeIterator
      (displayModeIterator), 'Can not get mode iterator');

    while (displayModeIterator.Next(displayMode) = S_OK) do
      l_modeList.Add(displayMode);

    CheckAndRaiseIfFailed(l_deckLinkInput.SetCallback(self),
      'Set callback failed');

    displayMode := l_modeList.Items[0];
    BMDDisplayMode := displayMode.GetDisplayMode();
    displayMode.GetName(displayName);
    AddToLog('Initial input mode - ' + displayName);

    videoInputFlags := bmdVideoInputFlagDefault or
      bmdVideoInputEnableFormatDetection;
    CheckAndRaiseIfFailed(l_deckLinkInput.EnableVideoInput(BMDDisplayMode,
      bmdFormat8BitYUV, videoInputFlags), 'Cannot enable video input');

    CheckAndRaiseIfFailed(l_deckLinkInput.EnableAudioInput
      (bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger,
      MaxAudioChannels), 'Cannot enable audio input');

    CheckAndRaiseIfFailed(l_deckLinkInput.StartStreams, 'Start streams failed');

    isStarted := true;
    AddToLog('decklink_capture started');
  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
    else
      AddToLog('Неизвестная ошибка');
  end;
end;

procedure Tdecklink_capturer.OnModeChange;
var
  videoInputFlags: _BMDVideoInputFlags;
  displayName: WideString;
begin
  if not isStarted then
    exit;

  try
    isStarted := false;

    CheckAndRaiseIfFailed(lastDetectedMode.GetName(displayName),
      'Cannot get modename');

    CheckAndRaiseIfFailed(l_deckLinkInput.StopStreams, 'Stop streams failed');
    //
    CheckAndRaiseIfFailed(l_deckLinkInput.DisableAudioInput,
      'Disable audio input failed');

    CheckAndRaiseIfFailed(l_deckLinkInput.DisableVideoInput,
      'Disable video input failed');

    videoInputFlags := bmdVideoInputFlagDefault or
      bmdVideoInputEnableFormatDetection;
    CheckAndRaiseIfFailed(l_deckLinkInput.EnableVideoInput
      (lastDetectedMode.GetDisplayMode, bmdFormat8BitYUV, videoInputFlags),
      'Cannot enable video input');

    CheckAndRaiseIfFailed(l_deckLinkInput.EnableAudioInput
      (bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger,
      MaxAudioChannels), 'Cannot enable audio input');

    CheckAndRaiseIfFailed(l_deckLinkInput.StartStreams, 'Start streams failed');

    AddToLog('capture restarted as input mode has changed to ' + displayName);
    isStarted := true;
  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
      AddToLog('capture restart failed/modname:' + displayName);
    end;
    else
      AddToLog('Неизвестная ошибка');
  end;

end;

procedure Tdecklink_capturer.Stop;
begin
  if not isStarted then
    exit;

  try
    CheckAndRaiseIfFailed(l_deckLinkInput.StopStreams, 'Stop streams failed');

    CheckAndRaiseIfFailed(l_deckLinkInput.DisableAudioInput,
      'Disable audio input failed');

    CheckAndRaiseIfFailed(l_deckLinkInput.DisableVideoInput,
      'Disable video input failed');

    isStarted := false;
    AddToLog('decklink_capture stopped');
  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
    else
      AddToLog('Неизвестная ошибка');
  end;

end;

function Tdecklink_capturer.VideoInputFormatChanged(notificationEvents
  : _BMDVideoInputFormatChangedEvents;
  const newDisplayMode: IDeckLinkDisplayMode;
  detectedSignalFlags: _BMDDetectedVideoInputFormatFlags): HResult;
var
  mode_name: WideString;
begin
  lastDetectedMode := newDisplayMode;

  WinAPI.Windows.PostMessage((Owner as TForm).Handle,
    BMModeChangeMessage, 0, 0);

  Result := S_OK;
end;

function Tdecklink_capturer.VideoInputFrameArrived(const videoFrame
  : IDeckLinkVideoInputFrame;
  const audioPacket: IDeckLinkAudioInputPacket): HResult;
var
  tmp_frame: TOne_frame;
  tmpptr: PData16;
  tmpptrp: Pointer;
  bufsize: integer;
  i, i1: integer;
  hw_timestamp, hw_timestamp2, hw_framedur, time_stamp: Int64;
begin
  QueryPerformanceCounter(hw_timestamp2);

  try
    hw_timestamp := -1;
    if Assigned(videoFrame) then
    begin
      CheckAndRaiseIfFailed(videoFrame.GetHardwareReferenceTimestamp(1000,
        hw_timestamp, hw_framedur), 'Hardware timestamp error');
    end;

    if Assigned(audioPacket) then
    begin
      bufsize := audioPacket.GetSampleFrameCount;
      CheckAndRaiseIfFailed(audioPacket.GetBytes(tmpptrp),
        'Audio packet GetBytes Error');

      if hw_timestamp > 0 then
        time_stamp := hw_timestamp
      else
        time_stamp := hw_timestamp2 div (ts_frequency div 1000);

      if Assigned(out_frames1) then
      begin
        tmpptr := tmpptrp;

        tmp_frame := TOne_frame.Create(bufsize, time_stamp);

        // get sample value
        if (UseChannel1 > 0) and (UseChannel1 < MaxAudioChannels) then
          i1 := UseChannel1
        else
          i1 := 0;

        for i := 0 to bufsize - 1 do
        begin
          tmp_frame.data^[i] := tmpptr^[i1];
          inc(i1, MaxAudioChannels);
        end; // for

        out_frames1.Add(tmp_frame);
      end;

      if Assigned(out_frames2) then
      begin
        tmpptr := tmpptrp;

        tmp_frame := TOne_frame.Create(bufsize, time_stamp);

        // get sample value
        if (UseChannel2 > 0) and (UseChannel2 < MaxAudioChannels) then
          i1 := UseChannel2
        else
          i1 := 0;

        for i := 0 to bufsize - 1 do
        begin
          tmp_frame.data^[i] := tmpptr^[i1];
          inc(i1, MaxAudioChannels);
        end; // for

        out_frames2.Add(tmp_frame);
      end;

    end;
    // AddToLog('tick ' + inttostr(audioPacket.GetSampleFrameCount));
  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
    else
      AddToLog('Неизвестная ошибка');
  end;

  Result := S_OK;
end;

procedure Tdecklink_capturer.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    exit;

  OutputText.Add(TOne_text.Create(instring));
end;

procedure Tdecklink_capturer.CheckAndRaiseIfFailed(hr: HResult;
  ErrorString: string);
var
  ErrMsg: string;
begin
  if FAILED(hr) then
  begin
    SetLength(ErrMsg, 512);
    AMGetErrorText(hr, PChar(ErrMsg), 512);
    raise EMyOwnException.Create(ErrorString + Trim(ErrMsg));
  end;
end;

function Tdecklink_capturer.ModeFromNumber(in_number: TOleEnum)
  : IDeckLinkDisplayMode;
var
  i: integer;
  BMDDisplayMode: _BMDDisplayMode;
begin
  Result := nil;
  for i := 0 to l_modeList.Count - 1 do
  begin
    BMDDisplayMode := l_modeList.Items[i].GetDisplayMode;
    if BMDDisplayMode = in_number then
    begin
      Result := l_modeList.Items[i];
      break;
    end;
  end;
end;

end.
