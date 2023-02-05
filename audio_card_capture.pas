unit audio_card_capture;

interface

uses
  System.Classes, System.Types, System.SysUtils, System.DateUtils,
  System.Generics.Collections,
  VCL.StdCtrls,
  WinAPI.Windows, WinAPI.Messages, WinAPI.MMsystem,
  UnitOneBuff, UnitOneText, UnitOneDevice;

const
  // длина буфера в семплах
  bufsize = (48000 div 25);
  // количество буферов
  bufnum = 16;

type
  Taudio_card_capturer = class(TComponent)
  private
    hBufHead: array [0 .. bufnum - 1] of THANDLE;
    hBufHeadMem: array [0 .. bufnum - 1] of THANDLE;
    //
    WaveIn: HWAVEIN;
    pBufHead: array [0 .. bufnum - 1] of PWaveHdr;
    data16: PData16;
    was_stop_request: boolean;
    ts_frequency: Int64;
    procedure AddToLog(instring: string);
  public
    OutputText: TTLtext_list;
    SelectedDevice: integer;
    UseChannel1, UseChannel2: integer;
    //
    out_frames1, out_frames2: TTLframes_list;
    procedure Start;
    procedure Stop;
    function AddDevices(tmp_cb: TComboBox): boolean;
  end;

  EMyOwnException = class(Exception);

procedure OnWaveIn(hwi: HWAVEIN; uMsg, dwInstance, dwParam1,
  dwParam2: DWORD); stdcall;

implementation

{ audio_card_capturer }
function Taudio_card_capturer.AddDevices(tmp_cb: TComboBox): boolean;
var
  SoundCardsNum: integer;
  i: integer;
  RResult: MMRESULT;
  DeviceCaps: TWaveInCaps;
  ErrTxt: array [0 .. 511] of char;
  in_device: TOneDevice;
begin
  SoundCardsNum := waveInGetNumDevs();

  for i := 0 to SoundCardsNum - 1 do
  begin
    RResult := waveInGetDevCaps(i, @DeviceCaps, SizeOf(TWaveInCaps));
    if RResult <> 0 then
    begin
      waveInGetErrorText(RResult, ErrTxt, 512);
      AddToLog('Device #' + inttostr(i) + ' - can not get properties: '
        + ErrTxt);
    end
    else
    begin
      if Pos('Blackmagic', DeviceCaps.szPname) <= 0 then
      begin
        in_device := TOneDevice.Create;
        in_device.isOldAudio := true;
        in_device.Name := 'OL:' + DeviceCaps.szPname;
        in_device.DevNo := i;
        in_device.Channels := DeviceCaps.wChannels;

        tmp_cb.AddItem(in_device.Name, in_device);
      end;
    end;
  end;

end;

procedure Taudio_card_capturer.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(instring));
end;

procedure Taudio_card_capturer.Start;
var
  pWaveFormatHeader: PWaveFormatEx;
  hWaveFormatHeader: THANDLE;
  RResult: MMRESULT;

  ErrTxt: array [0 .. 511] of char;
  BufLen: Word;
  i: integer;
begin
  AddToLog('audio_card_capture started');
  was_stop_request := false;

  QueryPerformanceFrequency(ts_frequency);

  try
    // резервируем места под заголовки
    hWaveFormatHeader := LocalAlloc(LMEM_MOVEABLE, SizeOf(TWaveFormatEx));
    if hWaveFormatHeader = 0 then
      raise EMyOwnException.Create('WaveFormatEx local alloc error');

    pWaveFormatHeader := LocalLock(hWaveFormatHeader);
    if pWaveFormatHeader = nil then
      raise EMyOwnException.Create('WaveFormatEx local lock error');

    // заполняем хидер
    with pWaveFormatHeader^ do
    begin
      wFormatTag := WAVE_FORMAT_PCM;
      nChannels := 2;
      nSamplesPerSec := 48000;
      wBitsPerSample := 16;
      nBlockAlign := nChannels * (wBitsPerSample div 8);
      nAvgBytesPerSec := nSamplesPerSec * nBlockAlign;
      cbSize := 0;
    end;

    // открываем аудиоустройство
    RResult := WaveInOpen(@WaveIn, SelectedDevice, pWaveFormatHeader,
      DWORD(@OnWaveIn), DWORD(Self), CALLBACK_FUNCTION);
    if RResult <> MMSYSERR_NOERROR then
    begin
      LocalUnlock(hWaveFormatHeader);
      LocalFree(hWaveFormatHeader);
      waveInGetErrorText(RResult, ErrTxt, 512);
      raise EMyOwnException.Create('WaveInOpen error: ' + ErrTxt);
    end;

    // длина буфера в байтах
    BufLen := pWaveFormatHeader^.nBlockAlign * bufsize;

    LocalUnlock(hWaveFormatHeader);
    LocalFree(hWaveFormatHeader);

    // получаем память под заголовки буферов и сами буфера
    for i := 0 to bufnum - 1 do
    begin
      hBufHead[i] := GlobalAlloc(GMEM_MOVEABLE or GMEM_SHARE, SizeOf(TWaveHdr));
      if hBufHead[i] = 0 then
        raise EMyOwnException.Create('Buffer header #' + inttostr(i) +
          ' global alloc error');
      pBufHead[i] := GlobalLock(hBufHead[i]);
      if pBufHead[i] = nil then
        raise EMyOwnException.Create('Buffer header #' + inttostr(i) +
          ' global lock error');
    end;

    // заполняем заголовок буферов
    for i := 0 to bufnum - 1 do
    begin
      with pBufHead[i]^ do
      begin
        hBufHeadMem[i] := GlobalAlloc(GMEM_MOVEABLE or GMEM_SHARE, BufLen);
        if hBufHeadMem[i] = 0 then
          raise EMyOwnException.Create('Buffer memory header #' + inttostr(i) +
            ' global alloc error');
        lpData := GlobalLock(hBufHeadMem[i]);
        if lpData = nil then
          raise EMyOwnException.Create('Buffer memory header #' + inttostr(i) +
            ' global lock error');
        dwBufferLength := BufLen;
        dwFlags := 0;
        dwUser := i;
      end;
    end;

    // подготавливаем буферы
    for i := 0 to bufnum - 1 do
    begin
      RResult := WaveInPrepareHeader(WaveIn, pBufHead[i], SizeOf(TWaveHdr));
      if RResult <> MMSYSERR_NOERROR then
      begin
        waveInGetErrorText(RResult, ErrTxt, 512);
        raise EMyOwnException.Create('WaveInPrepareHeader error: ' + ErrTxt);
      end;
    end;

    // подключаем буферы к устройству
    for i := 0 to bufnum - 1 do
    begin
      RResult := WaveInAddBuffer(WaveIn, pBufHead[i], SizeOf(TWaveHdr));
      if RResult <> MMSYSERR_NOERROR then
      begin
        waveInGetErrorText(RResult, ErrTxt, 512);
        raise EMyOwnException.Create('WaveInAddBuffer error: ' + ErrTxt);
      end;
    end;

    RResult := WaveInStart(WaveIn);
    if RResult <> MMSYSERR_NOERROR then
    begin
      waveInGetErrorText(RResult, ErrTxt, 512);
      raise EMyOwnException.Create('WaveInStart error: ' + ErrTxt);
    end;

    // получаем буфер под обработку
    GetMem(data16, bufsize * 4);
    if not Assigned(data16) then
      raise EMyOwnException.Create('Cant get buffer for tmp');

  except
    on E: EMyOwnException do
    begin
      AddToLog(E.Message);
    end;
    else
      AddToLog('Unknown error');
  end;
end;

procedure Taudio_card_capturer.Stop;
var
  i: integer;
begin
  was_stop_request := true;

  WaveInReset(WaveIn);

  for i := 0 to bufnum - 1 do
    WaveInUnPrepareHeader(WaveIn, pBufHead[i], SizeOf(TWaveHdr));
  WaveInClose(WaveIn);

  for i := 0 to bufnum - 1 do
  begin
    GlobalUnlock(hBufHeadMem[i]);
    GlobalFree(hBufHeadMem[i]);
    GlobalUnlock(hBufHead[i]);
    GlobalFree(hBufHead[i]);
  end;

  if Assigned(data16) then
    FreeMem(data16);
end;

// callback процедура - вызывается по заполнению буфера (событие MM_WIM_DATA)
procedure OnWaveIn(hwi: HWAVEIN; uMsg, dwInstance, dwParam1,
  dwParam2: DWORD); stdcall;
var
  i, i1: integer;
  tmp_frame: TOne_frame;
  time_stamp, hw_time_stamp: Int64;
  tmp_owner: Taudio_card_capturer;
begin
  if uMsg <> WIM_DATA then
    Exit;

  tmp_owner := Taudio_card_capturer(dwInstance);
  if tmp_owner.was_stop_request then
    Exit;

  QueryPerformanceCounter(hw_time_stamp);

  // copy data to tmp buffer
  Move(PWaveHdr(dwParam1)^.lpData^, tmp_owner.data16^, bufsize * 4);

  // return frame to buffer queue
  PWaveHdr(dwParam1)^.dwFlags := (PWaveHdr(dwParam1)^.dwFlags) and
    not WHDR_DONE;
  WaveInAddBuffer(hwi, tmp_owner.pBufHead[PWaveHdr(dwParam1)^.dwUser],
    SizeOf(TWaveHdr));

  time_stamp := hw_time_stamp div (tmp_owner.ts_frequency div 1000);

  // frame for channel1
  tmp_frame := TOne_frame.Create(bufsize, time_stamp);

  // get sample value
  i1 := tmp_owner.UseChannel1;

  for i := 0 to bufsize - 1 do
  begin
    tmp_frame.data^[i] := tmp_owner.data16^[i1];
    inc(i1, 2);
  end; // for

  tmp_owner.out_frames1.Add(tmp_frame);

  // frame for channel2
  tmp_frame := TOne_frame.Create(bufsize, time_stamp);

  // get sample value
  i1 := tmp_owner.UseChannel2;

  for i := 0 to bufsize - 1 do
  begin
    tmp_frame.data^[i] := tmp_owner.data16^[i1];
    inc(i1, 2);
  end; // for

  tmp_owner.out_frames2.Add(tmp_frame);
end;

end.
