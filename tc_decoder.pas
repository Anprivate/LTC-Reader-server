unit tc_decoder;

interface

uses
  System.Classes, System.Generics.Collections, System.SysUtils, System.Math,
  System.DateUtils,
  Winapi.Messages, Winapi.Windows,
  UnitOneBuff, UnitOneText;

type
  Ttc_decoder_thread = class(TThread)
  public
    in_frames: TTLframes_list;
    TCrawdata: array [0 .. 3] of Word;
    TCdifference: Int64;
    TCisReady: boolean;
    IDstring: string;
    OutputText: TTLtext_list;
    MsgID: Cardinal;
    MainHandle: hWnd;
    // output parameters
    AudioData: TOne_frame;
  private
    procedure SendToMain(param1, param2: Int64);
    procedure SendContinueMessage(intc: Int64);
    procedure SendStopMessage;
    procedure AddToLog(instring: string);
  protected
    procedure Execute; override;
  end;

implementation

function TCtoString(intc: integer): string;
var
  iHours, iMinutes, iSeconds, iFrames, tmp: integer;
begin
  tmp := intc;
  iHours := tmp div 90000;
  tmp := tmp mod 90000;
  iMinutes := tmp div 1500;
  tmp := tmp mod 1500;
  iSeconds := tmp div 25;
  iFrames := tmp mod 25;
  TCtoString := format('%.2u', [iHours]) + ':' + format('%.2u', [iMinutes]) +
    ':' + format('%.2u', [iSeconds]) + ':' + format('%.2u', [iFrames]);
end;

{ Ttc_decoder_thread }

procedure Ttc_decoder_thread.AddToLog(instring: string);
begin
  if not Assigned(OutputText) then
    Exit;

  OutputText.Add(TOne_text.Create(IDstring + instring));
end;

procedure Ttc_decoder_thread.Execute;
var
  one_frame: TOne_frame;
  tmp_list: TList<TOne_frame>;

  SampleValue: integer;

  SummPlus, SummMinus, CntrPlus, CntrMinus, SampleSumm: Int64;
  AvrgPlus, AvrgMinus, MaxPlus, MaxMinus: integer;
  WasJump, WasMinus, WasPlus, WasOne, WasError, WasSyncWord: boolean;
  LastJump, interval, short_interval: integer;
  tc_int, prev_tc_int, next_tc_int: integer;
  tc_int_in_ms: Int64;
  correct_frames_counter: integer;

  wData: Word;
  wDataOut: array [0 .. 3] of Word;
  WordCounter: integer;
  BitCounter: integer;
  DataSize: integer;

  i, i1: integer;

  LastTCrxed: TDateTime;
  WasStopSent: boolean;
begin
  WasMinus := false;
  WasPlus := false;
  WasOne := false;

  WasError := true;
  WasSyncWord := false;
  prev_tc_int := -1;

  LastJump := 0;
  SampleSumm := 0;
  wData := 0;
  WordCounter := -1;
  BitCounter := -1;

  TCisReady := false;
  correct_frames_counter := 0;

  LastTCrxed := Now();
  WasStopSent := false;

  AddToLog('tc_decoder started');

  while not Terminated do
  begin
    if not Assigned(in_frames) then
      break;

    one_frame := nil;
    tmp_list := in_frames.LockList;
    if tmp_list.Count > 0 then
    begin
      one_frame := tmp_list.Items[0];
      tmp_list.Delete(0);
    end;
    in_frames.UnlockList;

    if not Assigned(one_frame) then
    begin
      Sleep(2);
      continue;
    end;

    // считаем среднее значение
    SummPlus := 0; // сумма значений выше нуля
    CntrPlus := 0; // сколько значений выше нуля
    SummMinus := 0; // сумма значений ниже нуля
    CntrMinus := 0; // сколько значений ниже нуля
    MaxPlus := 0; // максимальное значение выше нуля
    MaxMinus := 0; // минимальное значение ниже нуля

    for i := 0 to one_frame.samples - 1 do
    begin
      SampleValue := one_frame.data^[i];

      if SampleValue > 0 then
      begin
        SummPlus := SummPlus + SampleValue;
        if MaxPlus < SampleValue then
          MaxPlus := SampleValue;
        inc(CntrPlus);
      end; // if SampleValue > 0

      if SampleValue < 0 then
      begin
        SummMinus := SummMinus + SampleValue;
        if MaxMinus > SampleValue then
          MaxMinus := SampleValue;
        inc(CntrMinus);
      end; // if SampleValue < 0
    end;

    // calculating average plus and minus value (divided by 4 for trigger value)
    if CntrPlus > 0 then
      AvrgPlus := SummPlus div CntrPlus div 4
    else
      AvrgPlus := 10;

    if CntrMinus > 0 then
      AvrgMinus := SummMinus div CntrMinus div 4
    else
      AvrgMinus := -10;

    // decoding
    for i := 0 to one_frame.samples - 1 do
    begin
      SampleValue := one_frame.data^[i];

      SampleSumm := SampleSumm + SampleValue;

      // детектирование перехода через ноль с реализацией гистерезиса
      WasJump := false;
      if SampleValue > AvrgPlus then
      begin
        if WasMinus then
          WasJump := true;
        WasMinus := false;
        WasPlus := true;
      end
      else
      begin
        if SampleValue < AvrgMinus then
        begin
          if WasPlus then
            WasJump := true;
          WasPlus := false;
          WasMinus := true;
        end;
      end;

      // перехода не было - ничего не делаем
      if not WasJump then
        continue;

      // был переход - анализируем - что происходит
      // фиксируем интервал от последнего перехода
      short_interval := i - LastJump;

      // время передачи одного бита (в семплах) - 48000/25/80 = 24
      // при передачи единицы будет два интервала по 12 семплов
      // пороговая величина для различения 0 и 1 - 18
      // если интервал меньше 18, то передаётся первая половина "1" и
      // этот переход просто игнорируется
      if short_interval < (3 * one_frame.frequency div 25 div 80 div 4) then
        continue;

      interval := short_interval;

      // период существенно больше 24 - подрыв таймкода - сбрасываем переменные
      // ждем следующего синхрослова для выхода из состояния ошибки
      if interval > (5 * one_frame.frequency div 25 div 80 div 4) then
      begin
        WasError := true;
        WasSyncWord := false;
        prev_tc_int := -1;
      end
      else
      begin // normal interval
        // если среднее значение за период меньше - значит была "1"
        wData := wData shr 1;
        if Abs(SampleSumm div interval) < ((AvrgPlus - AvrgMinus) div 2) then
          // '1' detected
          wData := wData or $8000;

        // проверяем на синхрослово
        if wData = $BFFC then
        begin
          // пришло ли оно в правильном месте?
          if WordCounter <> 4 then
          begin
            WasError := true;
            WasSyncWord := false;
            prev_tc_int := -1;
          end
          else
          begin
            // если это не первое синхрослово, и пришло в правильном месте - пакет принят
            if WasSyncWord then
            begin
              WasError := false;

              tc_int := wDataOut[0] and $000F;
              inc(tc_int, 10 * ((wDataOut[0] and $0300) shr 8));
              inc(tc_int, 25 * (wDataOut[1] and $000F));
              inc(tc_int, 250 * ((wDataOut[1] and $0700) shr 8));
              inc(tc_int, 25 * 60 * (wDataOut[2] and $000F));
              inc(tc_int, 250 * 60 * ((wDataOut[2] and $0700) shr 8));
              inc(tc_int, 25 * 60 * 60 * (wDataOut[3] and $000F));
              inc(tc_int, 250 * 60 * 60 * ((wDataOut[3] and $0300) shr 8));

              tc_int_in_ms := tc_int * 40;
              TCdifference := one_frame.time_stamp - (one_frame.samples - i)
                div 48 - tc_int_in_ms;
              for i1 := 0 to 3 do
                TCrawdata[i1] := wDataOut[i1];
              TCisReady := true;

              if prev_tc_int >= 0 then
              begin
                next_tc_int := prev_tc_int + 1;
                if next_tc_int >= 24 * 60 * 60 * 25 then
                  next_tc_int := next_tc_int - 24 * 60 * 60 * 25;

                if next_tc_int = tc_int then
                begin
                  inc(correct_frames_counter);
                  if correct_frames_counter > 17 then
                    correct_frames_counter := 5;

                  if correct_frames_counter = 5 then
                    SendContinueMessage(TCdifference);

                  LastTCrxed := Now();
                  WasStopSent := false;
                end
                else
                begin
                  AddToLog('Подрыв тайм-кода с ' + TCtoString(prev_tc_int) +
                    ' на ' + TCtoString(tc_int));
                  correct_frames_counter := 0;
                end;
              end
              else
              begin
                // принят правильный тайм-код два кадра подряд
                AddToLog(' Принят тайм-код с ' + TCtoString(tc_int));
              end;
              prev_tc_int := tc_int;
            end;
            WasSyncWord := true;
          end;
          WordCounter := 0;
          BitCounter := 0;
        end
        else
        begin
          // обычные данные, обрабатываем словами по 16 бит
          inc(BitCounter);
          if BitCounter = 16 then
          begin
            // приняли слово
            BitCounter := 0;
            if WordCounter < 0 then
              WordCounter := 0
            else
            begin
              // в посылке 4 слова, складываем их в сырые данные
              if WordCounter < 4 then
                wDataOut[WordCounter] := wData;

              if WordCounter < 10 then
                inc(WordCounter);
            end;
            // if WordCounter < 0
          end; // if BitCounter = 16
        end; // if wData = $BFFC
      end; // if Interval > 30
      LastJump := i;
      SampleSumm := 0;
    end; // for i

    // после обработки кадра корректируем LastJump для корректной обработки следующего кадра
    LastJump := LastJump - one_frame.samples;

    if not Assigned(AudioData) then
    begin
      AudioData := one_frame;
    end
    else
    begin
      one_frame.Free;
    end;

    if not WasStopSent and (MillisecondsBetween(LastTCrxed, Now()) > 500) then
    begin
      SendStopMessage;
      WasStopSent := true;
    end;
  end;
end;

procedure Ttc_decoder_thread.SendContinueMessage(intc: Int64);
begin
  SendToMain(2, intc);
end;

procedure Ttc_decoder_thread.SendStopMessage;
begin
  SendToMain(3, 0);
end;

procedure Ttc_decoder_thread.SendToMain(param1, param2: Int64);
begin
  PostMessage(MainHandle, MsgID, param1, param2);
end;

end.
