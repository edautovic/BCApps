// ------------------------------------------------------------------------------------------------
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See License.txt in the project root for license information.
// ------------------------------------------------------------------------------------------------

namespace System.DataAdministration;

using System.Environment;

codeunit 1928 "Media Cleanup Impl."
{
    Access = Internal;
    InherentEntitlements = X;
    InherentPermissions = X;
    Permissions = tabledata "Tenant Media" = rimd,
                  tabledata "Tenant Media Set" = rimd;

    var
        TenantMediaNotTemporaryErr: Label 'The tenant media is not temporary.';
        MediaContentDefaultFileNameTxt: Label 'MediaContent', Comment = 'Name of the file that will be downloaded when you try to download media content without a file name.';
        CannotScheduleTaskRunManuallyQst: Label 'You are not able to schedule tasks, would you like to run the media cleanup in the foreground instead?';
        CleanupJobScheduledMsg: Label 'A background task has been scheduled to cleanup all detached Media.';
        ScheduledTaskAlreadyExistContinueQst: Label 'A task has already been scheduled for cleaning up data, do you want to continue?';
        CleanupFinishedSuccessfullyMsg: Label 'All detached media were successfully cleaned.';
        CleanupFailedMsg: Label 'There was an error while cleaning all detached media.';

    procedure GetDetachedTenantMedia(var TempTenantMediaVar: Record "Tenant Media" temporary; LoadMediaContent: Boolean; RecordLimit: Integer) AllDetachedMediaLoaded: Boolean
    var
        TenantMedia: Record "Tenant Media";
        Orphans: List of [Guid];
        Orphan: Guid;
        MediaLoaded: Integer;
    begin
        if not TempTenantMediaVar.IsTemporary() then
            Error(TenantMediaNotTemporaryErr);

        if LoadMediaContent then
            TenantMedia.SetAutoCalcFields(Content);

        // Media orphans
        Orphans := Media.FindOrphans();
        foreach Orphan in Orphans do begin
            TenantMedia.Get(Orphan);
            TempTenantMediaVar := TenantMedia;
            if TempTenantMediaVar.Insert() then;
            MediaLoaded += 1;
            if MediaLoaded >= RecordLimit then
                exit(false);
        end;

        exit(true);
    end;

    procedure GetTenantMediaFromDetachedMediaSet(var TempTenantMediaVar: Record "Tenant Media" temporary; LoadMediaContent: Boolean; RecordLimit: Integer) AllDetachedMediaLoaded: Boolean
    var
        TenantMedia: Record "Tenant Media";
        TenantMediaSet: Record "Tenant Media Set";
        Orphans: List of [Guid];
        Orphan: Guid;
        MediaLoaded: Integer;
    begin
        if not TempTenantMediaVar.IsTemporary() then
            Error(TenantMediaNotTemporaryErr);

        if LoadMediaContent then
            TenantMedia.SetAutoCalcFields(Content);

        // Media set orphans
        Orphans := MediaSet.FindOrphans();
        foreach Orphan in Orphans do begin
            TenantMediaSet.SetRange(ID, Orphan);
            if TenantMediaSet.FindSet() then
                repeat
                    if TenantMedia.Get(TenantMediaSet."Media ID".MediaId()) then begin
                        TempTenantMediaVar := TenantMedia;
                        if TempTenantMediaVar.Insert() then
                            MediaLoaded += 1;
                        if MediaLoaded >= RecordLimit then
                            exit(false);
                    end;
                until TenantMediaSet.Next() = 0;
        end;

        exit(true);
    end;

    procedure DownloadTenantMedia(MediaId: Guid): Boolean
    var
        TenantMedia: Record "Tenant Media";
        MediaInStream: InStream;
        FileName: Text;
    begin
        TenantMedia.SetAutoCalcFields(Content);
        TenantMedia.Get(MediaId);

        if not TenantMedia.Content.HasValue() then
            exit(false);

        TenantMedia.Content.CreateInStream(MediaInStream);

        FileName := TenantMedia."File Name";
        if FileName = '' then begin
            FileName := MediaContentDefaultFileNameTxt;
            if TenantMedia."Mime Type" = 'image/png' then
                FileName += '.png';
        end;

        DownloadFromStream(MediaInStream, '', '', '', FileName);
        exit(true);
    end;

    procedure DeleteTenantMedia(var TempTenantMedia: Record "Tenant Media" temporary)
    var
        TenantMediaSet: Record "Tenant Media Set";
        TenantMedia: Record "Tenant Media";
        MediaOrphans: List of [Guid];
        MediaSetOrphans: List of [Guid];
        MediaMissingDeletion: List of [Guid];
        Orphan: Guid;
    begin
        if not TempTenantMedia.IsTemporary() then
            Error(TenantMediaNotTemporaryErr);

        MediaOrphans := Media.FindOrphans();

        // First remove all media that aren't referenced by MediaSets
        if TempTenantMedia.FindSet() then
            repeat
                if MediaOrphans.Contains(TempTenantMedia.ID) then begin
                    TenantMedia.ID := TempTenantMedia.ID;
                    TenantMedia.Delete();
                    TempTenantMedia.Delete();
                end else
                    MediaMissingDeletion.Add(TempTenantMedia.ID);
            until TempTenantMedia.Next() = 0;

        // Next remove all MediaSets containing references to Media we want to remove
        MediaSetOrphans := MediaSet.FindOrphans();
        foreach Orphan in MediaSetOrphans do begin
            TenantMediaSet.SetRange(ID, Orphan);
            if TenantMediaSet.FindSet() then
                repeat
                    if MediaMissingDeletion.Contains(TenantMediaSet."Media ID".MediaId()) then
                        TenantMediaSet.Delete();
                until TenantMediaSet.Next() = 0;
        end;

        // Finally remove all media that now isn't referenced by a MediaSets (it's possible that an detached MediaSet and non-detached MediaSet is referencing the same Media)
        MediaOrphans := Media.FindOrphans();
        if TempTenantMedia.FindSet() then
            repeat
                if MediaOrphans.Contains(TempTenantMedia.ID) then begin
                    TenantMedia.ID := TempTenantMedia.ID;
                    TenantMedia.Delete();
                    TempTenantMedia.Delete();
                end;
            until TempTenantMedia.Next() = 0;
    end;

    procedure DeleteDetachedTenantMediaSet()
    var
        [SecurityFiltering(SecurityFilter::Ignored)]
        TenantMediaSet: Record "Tenant Media Set";
        SplitList: List of [List of [Guid]];
        MediaSetOrphans: List of [Guid];
        MediaOrphanSubList: List of [Guid];
        TenantMediaFilter: Text;
    begin
        if not TenantMediaSet.WritePermission() then
            exit;

        MediaSetOrphans := MediaSet.FindOrphans();
        SplitListIntoSubLists(MediaSetOrphans, 10, SplitList);
        foreach MediaOrphanSubList in SplitList do begin
            TenantMediaFilter := CreateOrFilter(MediaOrphanSubList);
            if TenantMediaFilter <> '' then begin
                TenantMediaSet.SetFilter(ID, TenantMediaFilter);
                TenantMediaSet.DeleteAll();
                Commit(); // Ensure we keep the progress even on timeout (in case of large amounts of detached media).
            end;
        end;
    end;

    procedure DeleteDetachedTenantMedia()
    var
        [SecurityFiltering(SecurityFilter::Ignored)]
        TenantMedia: Record "Tenant Media";
        SplitList: List of [List of [Guid]];
        MediaOrphans: List of [Guid];
        MediaOrphanSubList: List of [Guid];
        TenantMediaFilter: Text;
    begin
        if not TenantMedia.WritePermission() then
            exit;

        MediaOrphans := Media.FindOrphans();
        SplitListIntoSubLists(MediaOrphans, 100, SplitList);
        foreach MediaOrphanSubList in SplitList do begin
            TenantMediaFilter := CreateOrFilter(MediaOrphanSubList);
            if TenantMediaFilter <> '' then begin
                TenantMedia.SetFilter(ID, TenantMediaFilter);
                TenantMedia.DeleteAll();
                Commit(); // Ensure we keep the progress even on timeout (in case of large amounts of detached media).
            end;
        end;
    end;

    procedure ScheduleCleanupDetachedMedia()
    var
        ScheduledTask: Record "Scheduled Task";
    begin
        ScheduledTask.SetRange("Run Codeunit", Codeunit::"Media Cleanup Runner");
        ScheduledTask.SetRange("Is Ready", true);
        if not ScheduledTask.IsEmpty() then begin
            if not GuiAllowed() then
                exit;
            if not Confirm(ScheduledTaskAlreadyExistContinueQst) then
                exit;
        end;

        if not TaskScheduler.CanCreateTask() then begin
            if GuiAllowed() then
                if Confirm(CannotScheduleTaskRunManuallyQst) then
                    if Codeunit.Run(Codeunit::"Media Cleanup Runner") then
                        Message(CleanupFinishedSuccessfullyMsg)
                    else
                        Message(CleanupFailedMsg);
            exit;
        end;

        TaskScheduler.CreateTask(Codeunit::"Media Cleanup Runner", 0, true, CompanyName(), CurrentDateTime());

        if GuiAllowed() then
            Message(CleanupJobScheduledMsg);
    end;

    local procedure CreateOrFilter(var FilterList: List of [Guid]) FilterText: Text
    var
        Filter: Guid;
    begin
        foreach Filter in FilterList do
            FilterText += Format(Filter, 0, 4) + '|';
        FilterText := FilterText.TrimEnd('|');
    end;

    // 322, 100 will result in [[1, 100], [101, 200], [201, 300], [301, 322]]
    procedure SplitListIntoSubLists(var InputList: List of [Guid]; SubListCount: Integer; var SplitList: List of [List of [Guid]])
    var
        ListNumber: Integer;
        FromIndex: Integer;
        SubSize: Integer;
        NumberOfBatches: Integer;
        TempSubList: List of [Guid];
    begin
        NumberOfBatches := (InputList.Count() + SubListCount - 1) div SubListCount;

        for ListNumber := 1 to NumberOfBatches do begin
            Clear(TempSubList);
            FromIndex := (ListNumber - 1) * SubListCount + 1;
            SubSize := InputList.Count() - (FromIndex - 1);
            if SubSize > SubListCount then
                SubSize := SubListCount;
            TempSubList := InputList.GetRange(FromIndex, SubSize);
            SplitList.Add(TempSubList);
        end;
    end;
}