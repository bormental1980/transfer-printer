program fileprinter;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes,
  WinSpool,
  Windows, Vcl.Dialogs, vcl.Forms, vcl.Printers, vcl.StdCtrls, System.UITypes,
  Vcl.ComCtrls, Winapi.ShellAPI, System.IOUtils, System.RegularExpressions, System.Zip,
  System.Generics.Collections, System.Generics.Defaults, System.NetEncoding,
  System.Math;

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

procedure SendFileToRDPPrinter64(const FilePath, PrinterName: string);
var
  FS: TFileStream;
  Buffer: TBytes; // Размер кратен 3, чтобы Base64 не плодил знаки '=' в середине потока
  BytesRead, i: Integer;
  Base64: string;
  Form: TForm;
  Progress: TProgressBar;
  MarkerName, LineChunk: string;
  PrnIdx, Y, ChunkIdx, NumPage, NumRow, dimCol, dimRow: Integer;
  IsFirstPage: Boolean;

  procedure InputLine(ARow: Integer; AText: string);
  begin
    Printer.Canvas.TextOut(40, 20 + (ARow * Printer.Canvas.TextHeight('W')), AText);
  end;

  function GetSubstring(ARow: Integer; ABase64: string): string;
  var sp: Integer;
      line: string;
  begin
    sp := (ARow * dimCol) + 1;
    line := Copy(ABase64, sp, dimCol);
    Result := ARow.ToString + ':' + line;
  end;
begin
  PrnIdx := Printer.Printers.IndexOf(PrinterName);
  if PrnIdx < 0 then
  begin
    ShowMessage('printer not available.');
    Halt;
  end;
  Printer.PrinterIndex := PrnIdx;

  Form := GetProgressForm(Progress);
  Form.Caption := 'print file...';
  Form.Show;
  Application.ProcessMessages;

  Printer.Title := 'log_report';
  Printer.Orientation := poLandscape;
  Printer.BeginDoc;
  try
    Printer.Canvas.Font.Name := 'Courier New';
//    Printer.Canvas.Font.Size := 10;
    Printer.Canvas.Font.Height := -6;

    //размеры стр в символах
    dimCol := (Printer.PageWidth - 100) div Printer.Canvas.TextWidth('W') - 20;
    dimRow := (Printer.PageHeight - 100) div Printer.Canvas.TextHeight('W') - 20;

    Base64 := 'printertrans:' + ExtractFileName(FilePath) + ':' +
      TNetEncoding.Base64.EncodeBytesToString(TFile.ReadAllBytes(FilePath));
    Base64 := StringReplace(Base64, #13, '', [rfReplaceAll]);
    Base64 := StringReplace(Base64, #10, '', [rfReplaceAll]);

    try
      Progress.Min := 0;
      Progress.Max := Ceil(Ceil(Length(Base64) / dimCol) / dimRow);
      Progress.Position := 0;

      NumRow := 0;
      for i := 0 to Ceil(Length(Base64) / dimCol) do
        begin
          LineChunk := GetSubstring(i, Base64);
          InputLine(NumRow, LineChunk);
          if NumRow >= dimRow then
            begin
              Printer.NewPage;
              NumRow := 0;
              Progress.StepBy(1);
              Application.ProcessMessages;
            end;
          Inc(NumRow);
        end;

    finally
      Form.Free;
    end;

    Printer.EndDoc;
  except
    Printer.Abort;
    raise;
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

  Frm := TForm.Create(nil);
  try
    Frm.Caption := 'Выбор принтера';
    Frm.Width := 400;
    Frm.Height := 300;
    Frm.Position := poScreenCenter;
    Frm.BorderStyle := bsDialog; // Фиксированный размер окна

    ListBox := TListBox.Create(Frm);
    ListBox.Parent := Frm;
    ListBox.Left := 10;
    ListBox.Top := 10;
    ListBox.Width := 365;
    ListBox.Height := 200;

    for I := 0 to Printer.Printers.Count - 1 do
      ListBox.Items.Add(Printer.Printers[I]);

    if ListBox.Items.Count > 0 then
      ListBox.ItemIndex := 0;

    BtnOk := TButton.Create(Frm);
    BtnOk.Parent := Frm;
    BtnOk.Caption := 'ОК';
    BtnOk.Left := 150;
    BtnOk.Top := 220;
    BtnOk.Width := 90;
    BtnOk.Height := 30;
    BtnOk.ModalResult := mrOk; // Кнопка автоматически закроет форму с результатом mrOk

    if Frm.ShowModal = mrOk then
    begin
      if ListBox.ItemIndex >= 0 then
        Result := ListBox.Items[ListBox.ItemIndex];
    end;
  finally
    Frm.Free; // Освобождаем память формы и всех ее дочерних элементов
  end;
end;

procedure RestoreFromXpsFile64(const XpsFilePath: string);
var
  LinesList: TDictionary<Integer, string>;
  Line: string;
  UnzipPath, PagesPath: string;
  PageFiles, SplitLine: TArray<string>;
  I: Integer;
  XpsContent, GlyphsTag, ResultBase64, DecodedFileName, OutputPath: string;
  Match, MatchStr: TMatch;
  SB: TStringBuilder;
  OutputBytes: TArray<Byte>;
  BinaryFS: TFileStream;
  Form: TForm;
  Progress: TProgressBar;
begin
  UnzipPath := ExtractFilePath(XpsFilePath) + 'XpsTemp_';
  if TDirectory.Exists(UnzipPath) then TDirectory.Delete(UnzipPath, True);
  TDirectory.CreateDirectory(UnzipPath);

  try
    TZipFile.ExtractZipFile(XpsFilePath, UnzipPath);

    PagesPath := TPath.Combine(UnzipPath, TPath.Combine('Documents', TPath.Combine('1', 'Pages')));
    if not TDirectory.Exists(PagesPath) then
    begin
      ShowMessage('invalid XPS-document.');
      Exit;
    end;

    PageFiles := TDirectory.GetFiles(PagesPath, '*.fpage');
    TArray.Sort<string>(PageFiles);

    Form := GetProgressForm(Progress);
    Form.Caption := 'restore file...';
    Form.Show;
    Application.ProcessMessages;

    LinesList := TDictionary<Integer, string>.Create;
    try
      Progress.Min := 0;
      Progress.Max := Length(PageFiles);
      Progress.Position := 0;

      for i := 0 to Length(PageFiles) - 1 do
        begin
          XpsContent := TFile.ReadAllText(PageFiles[I], TEncoding.UTF8);

          for Match in TRegEx.Matches(XpsContent, '<Glyphs[^>]+/>') do
            begin
              GlyphsTag := Match.Value;
              MatchStr := TRegEx.Match(GlyphsTag, 'UnicodeString="([^"]+)"');

              if MatchStr.Success then
              begin
                Line := MatchStr.Groups[1].Value;
                SplitLine := StringReplace(Line, ':', '#', []).Split(['#']);
                if Length(SplitLine) = 2 then
                  LinesList.AddOrSetValue(SplitLine[0].ToInteger, SplitLine[1]);
              end;
            end;
          Progress.StepBy(1);
          Application.ProcessMessages;
        end;

      // Склеиваем отсортированные куски Base64
      i := 0;
      SB := TStringBuilder.Create;
      while LinesList.ContainsKey(i) do
        begin
          SB.Append(LinesList[i]);
          Inc(i);
        end;
      ResultBase64 := SB.ToString;
    finally
      if Assigned(SB) then SB.Free;
      LinesList.Free;
      Form.Free;
    end;

    if not ResultBase64.StartsWith('printertrans:') then
    begin
      ShowMessage('not transfer file.');
      Exit;
    end;
    Delete(ResultBase64, 1, 13); // Удаляем 'printertrans:'

    i := Pos(':', ResultBase64);
    if i = 0 then Exit;

    DecodedFileName := Copy(ResultBase64, 1, i - 1);
    Delete(ResultBase64, 1, i); // Отрезаем имя файла вместе с двоеточием
    ResultBase64 := TRegEx.Replace(ResultBase64, '[^A-Za-z0-9\+\/=]', '');

    OutputPath := ExtractFilePath(ParamStr(0)) + DecodedFileName;

    OutputBytes := TNetEncoding.Base64.DecodeStringToBytes(ResultBase64);

    if Length(OutputBytes) = 0 then
    begin
      ShowMessage('Error: Decoded data is empty.');
      Exit;
    end;

    // Пишем массив байт напрямую в файл
    BinaryFS := TFileStream.Create(OutputPath, fmCreate);
    try
      BinaryFS.Write(OutputBytes, Length(OutputBytes));
    finally
      BinaryFS.Free;
    end;

    ShowMessage('file restored.');
    OutputPath := '/select,"' + OutputPath + '"';
    ShellExecute(0, PChar('open'), PChar('explorer.exe'), PChar(OutputPath), nil, SW_SHOWNORMAL);

  finally
    if TDirectory.Exists(UnzipPath) then TDirectory.Delete(UnzipPath, True);
  end;
end;

var
  SrcFile, PrnName, ResFileName: string;
  FS: TFileStream;
  RS: TFileStream;
  Marker: AnsiString;
  Form: TForm;
  Progress: TProgressBar;
begin
  with TOpenDialog.Create(nil) do
    try
      Title := 'select file';
      InitialDir := TPath.GetDocumentsPath;
      Filter := 'all files файлы (*.*)|*.*';

      if Execute(0) then
      begin
        SrcFile := FileName;
      end;
    finally
      Free;
    end;

  if not FileExists(SrcFile) then
    begin
      ShowMessage('file not exists.');
      Halt;
    end;

  Marker := LowerCase(TPath.GetExtension(SrcFile));
  if (Marker = '.xps') or (Marker = '.oxps') then
    begin
      RestoreFromXpsFile64(SrcFile);
      Exit;
    end;

  PrnName := SelectPrinterGui;

  SendFileToRDPPrinter64(SrcFile, PrnName);

  ShowMessage('OK...');
  Exit;
end.

{var
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
    DocInfo.pDatatype := nil;//PChar('RAW'); // Отправляем как сырой текст

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
end;     }

  {FS := TFileStream.Create(SrcFile, fmOpenRead or fmShareDenyWrite);
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
  end;  }

