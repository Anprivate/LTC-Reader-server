unit wasapi_capture;

interface

uses
  System.Classes, System.Types, System.SysUtils, System.DateUtils,
  System.Generics.Collections,
  VCL.StdCtrls,
  WinAPI.Windows, WinAPI.Messages, WinAPI.MMsystem, WinAPI.ActiveX,
  WinAPI.DirectShow9,
  MMDeviceAPI,
  UnitOneBuff, UnitOneText, UnitOneDevice;

type
  TInputRecordThread = class(TThread)
  private
    procedure AddToLog(instring: string);
    procedure CheckAndRaiseIfFailed(hr: HResult; ErrorString: string);
  protected
    procedure Execute; override;
  public
    SelectedCardID: String;
    OutputText: TTLtext_list;
    UseChannel1, UseChannel2: integer;
    //
    out_frames1, out_frames2: TTLframes_list;
  end;

  Twasapi_capturer = class(TComponent)
  private
    InputRecordThread: TInputRecordThread;
    procedure AddToLog(instring: string);
    procedure CheckAndRaiseIfFailed(hr: HResult; ErrorString: string);
  public
    OutputText: TTLtext_list;
    UseChannel1, UseChannel2: integer;
    //
    out_frames1, out_frames2: TTLframes_list;
    //
    function AddDevices(tmp_cb: TComboBox): Boolean;
    procedure Start(selected_card_id: string);
    procedure Stop;
    procedure SetChannels(in1, in2: integer);
  protected
  end;

  EMyOwnException = class(Exception);

implementation

{ Twasapi_capturer }

function Twasapi_capturer.AddDevices(tmp_cb: TComboBox): Boolean;
const
  DEVICE_STATE_ACTIVE = $00000001;
  fmtidn: TGUID = '{A45C254E-DF1C-4EFD-8020-67D146A850E0}';
  fmtid: TGUID = '{F19F064D-082C-4E27-BC73-6882A1BB8E4C}';
var
  MMDevEnum: IMMDeviceEnumerator;
  MMDevCollection: IMMDeviceCollection;
  MMDev: IMMDevice;
  PropertyStore: IPropertyStore;
  PKEY_Device_FriendlyName: _tagpropertykey;

  num_devices: Cardinal;
  i: integer;
  varName: PROPVARIANT;
  DeviceName: string;
  in_device: TOneDevice;
  pwszID: PWideChar;
begin
  try
    CoInitializeEx(nil, COINIT_APARTMENTTHREADED);

    CheckAndRaiseIfFailed(CoCreateInstance(CLASS_MMDeviceEnumerator, nil,
      CLSCTX_ALL, IID_IMMDeviceEnumerator, MMDevEnum),
      'Cannot CoCreateInstance');

    CheckAndRaiseIfFailed(MMDevEnum.EnumAudioEndpoints(eCapture,
      DEVICE_STATE_ACTIVE, MMDevCollection), 'Cannot enumerate audio devices');

    CheckAndRaiseIfFailed(MMDevCollection.GetCount(num_devices),
      'Cannot get number of devices');

    for i := 0 to num_devices - 1 do
    begin
      CheckAndRaiseIfFailed(MMDevCollection.Item(i, MMDev),
        'Cannot get device from collection');

      CheckAndRaiseIfFailed(MMDev.GetId(pwszID), 'Cannot get device ID');

      CheckAndRaiseIfFailed(MMDev.OpenPropertyStore(STGM_READ, PropertyStore),
        'Cannot get property store');

      PKEY_Device_FriendlyName.fmtid := fmtidn;
      PKEY_Device_FriendlyName.pid := 14;

      // Get the endpoint's friendly-name property
      PropVariantInit(varName);
      CheckAndRaiseIfFailed(PropertyStore.GetValue(PKEY_Device_FriendlyName,
        &varName), 'Cannot get device name');
      DeviceName := varName.pwszVal;
      PropVariantClear(varName);

      //
      if Pos('Blackmagic', DeviceName) <= 0 then
      begin
        in_device := TOneDevice.Create;
        in_device.isWasapi := true;
        in_device.Name := 'WAS:' + DeviceName;
        in_device.DevNo := i;
        in_device.Channels := 2;
        in_device.dl_card := nil;
        in_device.wasapi_device_id := pwszID;

        tmp_cb.AddItem(in_device.Name, in_device);

        CoTaskMemFree(pwszID);
      end;
    end;

  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
    else
      AddToLog('Неизвестная ошибка');
  end;
end;

procedure Twasapi_capturer.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(instring));
end;

procedure Twasapi_capturer.CheckAndRaiseIfFailed(hr: HResult;
  ErrorString: string);
var
  ErrMsg: string;
begin
  if hr <> S_OK then
  begin
    SetLength(ErrMsg, 512);
    AMGetErrorText(hr, PChar(ErrMsg), 512);
    raise EMyOwnException.Create(ErrorString + Trim(ErrMsg));
  end;
end;

procedure Twasapi_capturer.SetChannels(in1, in2: integer);
begin
  if Assigned(InputRecordThread) then
  begin
    InputRecordThread.UseChannel1 := in1;
    InputRecordThread.UseChannel2 := in2;
  end;
end;

procedure Twasapi_capturer.Start(selected_card_id: string);
begin
  InputRecordThread := TInputRecordThread.Create(true);
  InputRecordThread.SelectedCardID := selected_card_id;
  InputRecordThread.OutputText := OutputText;
  InputRecordThread.UseChannel1 := UseChannel1;
  InputRecordThread.UseChannel2 := UseChannel2;
  InputRecordThread.out_frames1 := out_frames1;
  InputRecordThread.out_frames2 := out_frames2;

  InputRecordThread.FreeOnTerminate := false;
  InputRecordThread.Priority := tpTimeCritical;
  InputRecordThread.Start;
end;

procedure Twasapi_capturer.Stop;
begin
  if Assigned(InputRecordThread) then
  begin
    InputRecordThread.Terminate;
    while not InputRecordThread.Finished do
      Sleep(1);
    InputRecordThread.Free;
  end;

end;

{ TInputRecordThread }

procedure TInputRecordThread.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(instring));
end;

procedure TInputRecordThread.CheckAndRaiseIfFailed(hr: HResult;
  ErrorString: string);
var
  ErrMsg: string;
begin
  if hr <> S_OK then
  begin
    SetLength(ErrMsg, 512);
    AMGetErrorText(hr, PChar(ErrMsg), 512);
    raise EMyOwnException.Create(ErrorString + Trim(ErrMsg));
  end;
end;

procedure TInputRecordThread.Execute;
const
  WAVE_FORMAT_EXTENSIBLE = $FFFE;
  WAVE_FORMAT_IEEE_FLOAT = $0003;
  REFTIMES_PER_SEC = 10000000;
  REFTIMES_PER_MILLISEC = 10000;
type
  PWaveFormatExtensible = ^TWaveFormatExtensible;

  TWaveFormatExtensible = packed record
    Format: TWaveFormatEx;
    case Byte of
      0:
        (ValidBitsPerSample: Word; // bits of precision
          ChannelMask: LongWord; // which channels are present in stream
          SubFormat: TGUID);
      1:
        (SamplesPerBlock: Word); // valid if wBitsPerSample = 0
      2:
        (Reserved: Word); // If neither applies, set to zero.
  end;
var
  MMDevEnum: IMMDeviceEnumerator;
  MMDev: IMMDevice;
  AudioClient: IAudioClient;
  CaptureClient: IAudioCaptureClient;

  pWfx, pCloseWfx: PWaveFormatEx;
  pEx: PWaveFormatExtensible;

  tmpID: PWideChar;
  varName: PROPVARIANT;
  BufferFrameCount, NumFramesAvailable, Flags, StreamFlags,
    PacketLength: Cardinal;
  hnsRequestedDuration: Int64;
  pData: PByte;
  stream_pos, qpc_pos: UInt64;
  tmp_frame1, tmp_frame2: TOne_frame;
  i, i1, i2, frame_pos: integer;
  tmpptr: PData16;
  samples_in_frame, ticks_in_sample: integer;
  time_stamp: Int64;
begin
  inherited;
  try
    CoInitializeEx(nil, COINIT_APARTMENTTHREADED);

    CheckAndRaiseIfFailed(CoCreateInstance(CLASS_MMDeviceEnumerator, nil,
      CLSCTX_ALL, IID_IMMDeviceEnumerator, MMDevEnum),
      'Cannot CoCreateInstance CLASS_MMDeviceEnumerator');

    tmpID := PWideChar(SelectedCardID);
    CheckAndRaiseIfFailed(MMDevEnum.GetDevice(tmpID, MMDev),
      'Cannot get selected device');

    PropVariantInit(varName);
    CheckAndRaiseIfFailed(MMDev.Activate(IID_IAudioClient, CLSCTX_ALL, varName,
      Pointer(AudioClient)), 'Cannot activate device');
    PropVariantClear(varName);

    CheckAndRaiseIfFailed(AudioClient.GetMixFormat(pWfx),
      'Cannot get mix format');

    // http://www.ambisonic.net/mulchaud.html
    case pWfx.wFormatTag of
      WAVE_FORMAT_IEEE_FLOAT:
        begin
          pWfx.wFormatTag := WAVE_FORMAT_PCM;
          pWfx.wBitsPerSample := 16;
          pWfx.nBlockAlign := pWfx.nChannels * pWfx.wBitsPerSample div 8;
          pWfx.nAvgBytesPerSec := pWfx.nBlockAlign * pWfx.nSamplesPerSec;
        end;
      WAVE_FORMAT_EXTENSIBLE:
        begin
          pEx := PWaveFormatExtensible(pWfx);
          if not IsEqualGUID(KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, pEx.SubFormat)
          then
          begin
            Exit;
          end;

          pEx.SubFormat := KSDATAFORMAT_SUBTYPE_PCM;
          pEx.ValidBitsPerSample := 16;
          pWfx.wBitsPerSample := 16;
          pWfx.nBlockAlign := pWfx.nChannels * pWfx.wBitsPerSample div 8;
          pWfx.nAvgBytesPerSec := pWfx.nBlockAlign * pWfx.nSamplesPerSec;
        end;
    else
      Exit;
    end;

    CheckAndRaiseIfFailed(AudioClient.IsFormatSupported
      (AUDCLNT_SHAREMODE_SHARED, pWfx, pCloseWfx), 'Format not supported');

    AddToLog('Sample frequency: ' + pWfx.nSamplesPerSec.ToString);

    hnsRequestedDuration := REFTIMES_PER_SEC div 25;
    StreamFlags := 0;

    CheckAndRaiseIfFailed(AudioClient.Initialize(AUDCLNT_SHAREMODE_SHARED,
      StreamFlags, hnsRequestedDuration, 0, pWfx, nil),
      'Cannot initialize AudioClient');

    CheckAndRaiseIfFailed(AudioClient.GetBufferSize(BufferFrameCount),
      'Cannot GetBufferSize');

    CheckAndRaiseIfFailed(AudioClient.GetService(IID_IAudioCaptureClient,
      Pointer(CaptureClient)), 'Cannot GetService');

    // for positions calculation
    samples_in_frame := 40 * pWfx.nSamplesPerSec div 1000;
    ticks_in_sample := 10000000 div pWfx.nSamplesPerSec;

    // Start recording.
    AudioClient.Start();

    tmp_frame1 := nil;
    tmp_frame2 := nil;
    frame_pos := 0;

    while not Terminated do
    begin
      // Sleep for 1/4 the buffer duration.
      Sleep(BufferFrameCount * 250 div pWfx.nSamplesPerSec);

      CaptureClient.GetNextPacketSize(PacketLength);

      while PacketLength <> 0 do
      begin
        // Get the available data in the shared buffer.
        pData := nil;
        CaptureClient.GetBuffer(pData, NumFramesAvailable, Flags,
          stream_pos, qpc_pos);

        if (Flags and AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) <> 0 then
          AddToLog('Audio signal glitch');

        tmpptr := PData16(pData);

        if (UseChannel1 >= 0) and (UseChannel1 < 2) then
          i1 := UseChannel1
        else
          i1 := 0;

        if (UseChannel2 >= 0) and (UseChannel2 < 2) then
          i2 := UseChannel2
        else
          i2 := 0;

        for i := 0 to NumFramesAvailable - 1 do
        begin
          if not Assigned(tmp_frame1) then
          begin
            time_stamp := (qpc_pos + ticks_in_sample * i) div 10000;
            tmp_frame1 := TOne_frame.Create(samples_in_frame, time_stamp,
              pWfx.nSamplesPerSec);
            tmp_frame2 := TOne_frame.Create(samples_in_frame, time_stamp,
              pWfx.nSamplesPerSec);
            frame_pos := 0;
          end;

          if Assigned(tmpptr) then
            tmp_frame1.data^[frame_pos] := tmpptr^[i1]
          else
            tmp_frame1.data^[i] := 0;
          inc(i1, 2);

          if Assigned(tmpptr) then
            tmp_frame2.data^[frame_pos] := tmpptr^[i2]
          else
            tmp_frame2.data^[i] := 0;
          inc(i2, 2);

          inc(frame_pos);

          if frame_pos >= samples_in_frame then
          begin
            if Assigned(out_frames1) then
              out_frames1.Add(tmp_frame1)
            else
              tmp_frame1.Free;

            if Assigned(out_frames2) then
              out_frames2.Add(tmp_frame2)
            else
              tmp_frame2.Free;

            tmp_frame1 := nil;
            tmp_frame2 := nil;
          end;
        end; // for

        CaptureClient.ReleaseBuffer(NumFramesAvailable);
        CaptureClient.GetNextPacketSize(PacketLength);
      end;
    end;

    // Останавливаем запись.
    AudioClient.Stop();

  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
    else
      AddToLog('Неизвестная ошибка');
  end;

  if Assigned(pWfx) then
    CoTaskMemFree(pWfx);

end;

end.
