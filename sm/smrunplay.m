function data = smrunplay(scan, filename)
% data = smrun(scan, filename)
% data = smrun(filename) will assume scan = smscan
%
% scan: struct with the following fields:
%   disp: struct array with display information with  fields:  
%     channel: (index to saved channels)
%     dim: plot dimension (1 or 2)
%     loop: in what loop to display. defaults to one slower than 
%           acquisition. (somewhat rough)
% saveloop: loop in which to save data (default: second fastest)
% trafofn: list of global transformations.
% configfn: function struct with elements fn and args.
%           fn must be function handle, (why:change this) 
%           args is cell w/ length number of arguments. 
%            confignfn.fn(scan, configfn.args{:}) is called before all
%            other operations.
% cleanupfn; same, called before exiting.
% figure: number of figure to be plotted on. Uses next available figure
%         starting at 1000 if Nan. 
% loops: struct array with one element for each dimension, fields given
%        below. The last entry is for the fastest, innermost loop
%   fields of loops:
%   rng, 
%   npoints (empty means take rng as a vector, otherwise rng defines limits)
%   ramptime: min ramp time from point to point for each setchannel, 
%           currently converted to ramp rate assuming the same ramp rate 
%           at each point. If negative, the channel is only initialized at
%           the first point of the loop, and ramptime replaced by the 
%           slowest negative ramp time.
%           At the moment, this determines both the sample and the ramp
%           rate, i.e. the readout occurs as soon as a ramp finishes.
%           Ramptime can be a vector with an entry for each setchannel or
%           a single number for all channels. 
%   setchan
%   trafofn (cell array of function handles. Default: independent variable of this loop)
%   getchan
%   prefn (struct array with fields fn, args. Default empty)
%   postfn (default empty, currently a cell array of function handles)
%   datafn
%   procfn: struct array with fields fn and dim, one element for each
%           getchannel. dim replaces datadim, fn is a struct array with
%           fields fn and args. 
%           Optional fields: inchan, outchan, indata, outdata.
%           inchan, outchan refer to temporary storage space
%           indata, outdata refer to data space.
%           indata defaults to outdata if latter is given.
%           inchan, outdata default to index of procfn, i.e. the nth function uses the nth channel of its loop.
%           These fields can be used to implemnt complex processing by mixing and 
%           routing data between channels. Basically, any procfn can access any data read and any
%           previously recorded data. Further documentation will be provided when needed...
%   trigfn: executed only after programming ramps for autochannels.

% Copyright 2011 Hendrik Bluhm, Vivek Venkatachalam
% This file is part of Special Measure.
% 
%     Special Measure is free software: you can redistribute it and/or modify
%     it under the terms of the GNU General Public License as published by
%     the Free Software Foundation, either version 3 of the License, or
%     (at your option) any later version.
% 
%     Special Measure is distributed in the hope that it will be useful,
%     but WITHOUT ANY WARRANTY; without even the implied warranty of
%     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%     GNU General Public License for more details.
% 
%     You should have received a copy of the GNU General Public License
%     along with Special Measure.  If not, see <http://www.gnu.org/licenses/>.

global smdata;
global smscan;

%if no scan is sent to smrun, assume only field is filename
if ~isstruct(scan) 
    filename=scan;
    scan=smscan;
end

 % handle setting up self-ramping trigger for inner loop if none is
 % provided 
 % Assumes self ramping / no trigger if the ramptime is negative and either
 % there's no trigfn or the trigfn has field autoset set to true. 
 %Use smatrigfn 
if ~isempty(scan.loops(1).ramptime) && scan.loops(1).ramptime<0 && (~isfield(scan.loops(1),'trigfn') || ...
                                    isempty(scan.loops(1).trigfn) || ...
                                    (isfield(scan.loops(1).trigfn,'autoset') && scan.loops(1).trigfn.autoset))
    scan.loops(1).trigfn.fn=@smatrigfn;
    scan.loops(1).trigfn.args{1}=smchaninst(smscan.loops(1).setchan);
end

% set global constants for the scan, held in field scan.consts
if isfield(scan,'consts') && ~isempty(scan.consts)
    if ~isfield(scan.consts,'set')
        for i=1:length(scan.consts)
            scan.consts(i).set =1;
        end
    end
    setchans = {};
    setvals = [];
    for i=1:length(scan.consts)
        if scan.consts(i).set
            setchans{end+1}=scan.consts(i).setchan;
            setvals(end+1)=scan.consts(i).val;
        end
    end
    smset(setchans, setvals);
end

if isfield(scan, 'configfn')
    for i = 1:length(scan.configfn)
        scan = scan.configfn(i).fn(scan, scan.configfn(i).args{:});
    end
end

scandef = scan.loops;

if ~isfield(scan, 'disp') || isempty(scan.disp)
    disp = struct('loop', {}, 'channel', {}, 'dim', {});
else
    disp = scan.disp;
end

nloops = length(scandef);
nsetchan = zeros(1, nloops);
ngetchan = zeros(1, nloops);

% If the scan sent to smrun has fields scan.loops(i).setchanranges, the
% trafofn and rng fields have to be adjusted to convention
% If there is more than one channel being ramped, the range for the loop
% will be setchanranges{1}, and the channel values will be determined by linear
% mapping of this range onto the desired range for each channel.
for i=1:length(scandef)
    if isfield(scandef(i),'setchanranges')
        scandef(i).rng=scandef(i).setchanranges{1};
        for j=1:length(scandef(i).setchanranges)
            setchanranges = scandef(i).setchanranges{j};
            A = (setchanranges(2)-setchanranges(1))/(scandef(i).rng(end)-scandef(i).rng(1));
            B = (setchanranges(1)*scandef(i).rng(end)-setchanranges(2)*scandef(i).rng(1))/(scandef(i).rng(end)-scandef(i).rng(1));
            scandef(i).trafofn{j}=@(x, y) A*x(i)+B;
        end
    end
end

if ~isfield(scandef, 'npoints')
    [scandef.npoints] = deal([]);
end

if ~isfield(scandef, 'trafofn')
    [scandef.trafofn] = deal({});
end

if ~isfield(scandef, 'procfn')
    [scandef.procfn] = deal([]);
end

if ~isfield(scandef, 'ramptime')
     [scandef.ramptime] = deal([]);
end

if ~isfield(scan, 'saveloop')
    scan.saveloop = [2 1];
elseif length(scan.saveloop) == 1
    scan.saveloop(2) = 1;
end

if ~isfield(scan, 'trafofn')
    scan.trafofn = {};
end

%if nargin < 2
%    filename = 'data';
%end

if nargin >= 2 && filename(2)~=':'
    if isempty(filename);
        filename = 'data';
    end
    
    % relative path
    if all(filename ~= '/')
        filename = sprintf('sm_%s.mat', filename);
    end
    
    str = '';
    while (exist(filename, 'file') || exist([filename, '.mat'], 'file')) && ~strcmp(str, 'yes')
        fprintf('File %s exists. Overwrite? (yes/no)', filename);
        while 1
            str = input('', 's');
            switch str
                case 'yes'
                    break;
                case 'no'
                    filename = sprintf('sm_%s.mat', input('Enter new name:', 's'));
                    break
            end
        end
    end
end

%sets the points that determine ramp? 
for i = 1:nloops
    % If only have one of npoints, rng, can make up the rest. 
    if isempty(scandef(i).npoints)        
        scandef(i).npoints = length(scandef(i).rng);
    elseif isempty(scandef(i).rng)        
        scandef(i).rng = 1:scandef(i).npoints;
    else
        scandef(i).rng = linspace(scandef(i).rng(1), scandef(i).rng(end), ...
            scandef(i).npoints);
    end

    % default for ramp?
    
    scandef(i).setchan = smchanlookup(scandef(i).setchan);
    scandef(i).getchan = smchanlookup(scandef(i).getchan);
    %simple
    nsetchan(i) = length(scandef(i).setchan);

    %procfn defaults
    if ~isempty(scandef(i).getchan) && isempty(scandef(i).procfn) % no processing at all, each channel saved
        [scandef(i).procfn(1:length(scandef(i).getchan)).fn] = deal([]);
    end
    
    % number of channels saved.
    ngetchan(i) = 0;%length(scandef(i).procfn); 
    
    %Figure out how many data channels are needed
    % Also, sets the outdataNum and outdataProc, which specify 
    for j = 1:length(scandef(i).procfn)
        % set ngetchan to largest outdata index or procfn index where outdata not given
        if isfield(scandef(i).procfn(j).fn, 'outdata')
            % Outdata will create a datachannel at the number outdata, even
            % if larger than procfns/getchans. 
         
            ngetchan(i) = max([ngetchan(i), scandef(i).procfn(j).fn.outdata]);
            
            % index lookup from data index to function index
            noutdata = length([scandef(i).procfn(j).fn.outdata]); % number of outdata chans 
            dataindPrev = sum(ngetchan(1:i-1)); % data channel index for previous loops. 
            
            %First gives which outdata chan index, next which procfn index.    
             outdataInd = [scandef(i).procfn(j).fn.outdata]; 
             outdataNum(outdataInd+dataindPrev) = 1:noutdata;            
             procInd(outdataInd+dataindPrev) = j * ones(1, noutdata);                  
        else
            dataind = sum(ngetchan(1:i-1)) + j;
            procInd(dataind) = j; 
            outdataNum(dataind) = 1; 
            ngetchan(i) = max(ngetchan(i), j);
        end
        
        if isfield(scandef(i).procfn(j).fn, 'outdata') && ~isfield(scandef(i).procfn(j).fn, 'indata')
            [scandef(i).procfn(j).fn.indata] = deal(scandef(i).procfn(j).fn.outdata);
        end
            
        if ~isfield(scandef(i).procfn(j).fn, 'inchan')
            for k = 1:length(scandef(i).procfn(j).fn)                
                scandef(i).procfn(j).fn(k).inchan = j;
            end
        end
               
        if ~isempty(scandef(i).procfn(j).fn) && ~isfield(scandef(i).procfn(j).fn, 'outchan') 
            [scandef(i).procfn(j).fn.outchan] = deal(scandef(i).procfn(j).fn.inchan);
        end
        
        %FIX ME
        if ~isempty(scandef(i).procfn(j).fn)
          for k = 1:length(scandef(i).procfn(j).fn)
              if isempty(scandef(i).procfn(j).fn(k).inchan)
                  scandef(i).procfn(j).fn(k).inchan = j;
              end
              if isempty(scandef(i).procfn(j).fn(k).outchan)
                  scandef(i).procfn(j).fn(k).outchan = scandef(i).procfn(j).fn(k).inchan;
              end
          end
        end       
    end
        
    if isempty(scandef(i).ramptime)
        scandef(i).ramptime = nan(nsetchan(i), 1);
    elseif length(scandef(i).ramptime) == 1 
        scandef(i).ramptime = repmat(scandef(i).ramptime, size(scandef(i).setchan));
    end
   
    if isempty(scandef(i).trafofn)
        scandef(i).trafofn = {};
       [scandef(i).trafofn{1:nsetchan(i)}] = deal(@(x, y) x(i));
    else
        for j = 1:nsetchan(i)
            if iscell(scandef(i).trafofn)
                if isempty(scandef(i).trafofn{j})
                    scandef(i).trafofn{j} = @(x, y) x(i);
                end
            elseif isempty(scandef(i).trafofn(j).fn)
                scandef(i).trafofn(j).fn = @(x, y) x(i);
                scandef(i).trafofn(j).args = {};
            end                
        end
    end
end

npoints = [scandef.npoints];
totpoints = prod(npoints);

datadim = zeros(sum(ngetchan), 5); % size of data read each time, can be up to 5d. 
%newdata = cell(1, max(ngetchan));
data = cell(1, sum(ngetchan));
ndim = zeros(1, sum(ngetchan)); % dimension of data read each time
dataloop = zeros(1, sum(ngetchan)); % loop in which each channel is read
disph = zeros(1, sum(ngetchan));
ramprate = cell(1, nloops);
tFrstPt = zeros(1, nloops);
getch = vertcat(scandef.getchan);
% get data dimension and allocate data memory
for i = 1:nloops
    instchan = vertcat(smdata.channels(scandef(i).getchan).instchan);            
    dataindPrev = sum(ngetchan(1:i-1));
    for j = 1:ngetchan(i)
        dataind = dataindPrev + j; % data channel index
        currProc = procInd(dataind); 
        if  isfield(scandef(i).procfn(currProc), 'dim') && ~isempty(scandef(i).procfn(currProc).dim)
            %get dimension of processed data if procfn used
            datadimCurr = scandef(i).procfn(currProc).dim(outdataNum(dataind), :);                                     
        else
            datadimCurr = smdata.inst(instchan(j, 1)).datadim(instchan(j, 2), :);
        end
        
        if all(datadimCurr <= 1)
            ndimCurr = 0; 
        else
            ndimCurr = find(datadimCurr > 1, 1, 'last');
        end
        
        % # of non-singleton dimensions
        datadimCurr = datadimCurr(1:ndimCurr); 
        if isfield(scandef(i).procfn(currProc).fn, 'outdata')
            dataCellSize = datadimCurr;
            % i.e. do not expand dimension if outdata given.
        else %collect points of size dimnsions outer + current loops 
            dataCellSize = [npoints(end:-1:i), datadimCurr];
        end
        if length(dataCellSize) == 1 %create many rows. 
            dataCellSize(2) = 1;
        end
        ndim(dataind) = ndimCurr;
        datadim(dataind, 1:ndimCurr) = datadimCurr;
        data{dataind} = nan(dataCellSize);
        dataloop(dataind) = i; 
    end
end
   
switch length(disp)
    case 1
        subplotSize = [1 1];         
    case 2
        subplotSize = [1 2];
   
    case {3, 4}
        subplotSize = [2 2];
        
    case {5, 6}
        subplotSize = [2 3];
        
    otherwise
        subplotSize = [3 3];
        disp(10:end) = [];
end

% determine the next available figure after 1000 for this measurement.  A
% figure is available unless its userdata field is the string 'SMactive'
if isfield(scan,'figure')
    figurenumber=scan.figure;
    if isnan(figurenumber)
        figurenumber = 1000;
        while ishandle(figurenumber) && strcmp(get(figurenumber,'userdata'),'SMactive')
            figurenumber=figurenumber+1;
        end
    end
else
    figurenumber=1000;
end
if ~ishandle(figurenumber);
    figure(figurenumber)
    set(figurenumber, 'pos', [10, 10, 800, 400]);
else
    figure(figurenumber);
    clf;
end

set(figurenumber,'userdata','SMactive'); % tag this figure as being used by SM
set(figurenumber, 'CurrentCharacter', char(0));

% default for disp loop
if ~isfield(disp, 'loop')
    for i = 1:length(disp)
        disp(i).loop = dataloop(disp(i).channel)-1;
    end
end

s.type = '()';
for i = 1:length(disp)    
    subplot(subplotSize(1), subplotSize(2), i);
    dispchan = disp(i).channel; %index of channel to be displayed    
    nDimCurr = ndim(dispchan); 
    
    % dataloop(dispchan) gives which loop the data is updated on    
    s.subs = num2cell(ones(1, nloops - dataloop(dispchan) + 1 + nDimCurr));
    [s.subs{end-disp(i).dim+1:end}] = deal(':');
    dispXval = dataloop(dispchan) - nDimCurr;  
    if dispXval < 1 % if this is < 1, don't have channel names or range to associate with x axis. 
        x = 1:datadim(dispchan, nDimCurr); % instead of range, just find number of data points. 
        xlab = 'n';
    else
        x = scandef(dispXval).rng; % if possible, set the x axis to have range of sweep channel and name of setchan.       
        if ~isempty(scandef(dispXval).setchan)
            xlab = smdata.channels(scandef(dispXval).setchan(1)).name;
        else
            xlab = '';
        end
    end

    if disp(i).dim == 2        
        if dispXval < 0 % if this is < 0, we don't have channel names to associate with y axis. 
            y = 1:datadim(dispchan, nDimCurr-1);
            ylab = 'n';
        else
            y = scandef(dispXval + 1).rng;
            if ~isempty(scandef(dispXval + 1).setchan)
                ylab = smdata.channels(scandef(dispXval + 1).setchan(1)).name;
            else
                ylab = '';
            end
        end
        z = zeros(length(y), length(x));
        z(:, :) = subsref(data{dispchan}, s);
        disph(i) = imagesc(x, y, z);
        %disph(i) = imagesc(x, y, permute(subsref(data{dc}, s), [ndim(dc)+(-1:0), 1:ndim(dc)-2]));
        
        set(gca, 'YDir', 'Normal');
        colorbar;
        if dispchan <= length(getch)
            title(smdata.channels(getch(dispchan)).name);
        end
        xlabel(xlab);
        ylabel(ylab);
    else
        y = zeros(size(x));
        y(:) = subsref(data{dispchan}, s);
        disph(i) = plot(x, y);
        %permute(subsref(data{dc}, s), [ndim(dc), 1:ndim(dc)-1])
        xlim(sort(x([1, end])));
        xlabel(xlab);
        if dispchan <= length(getch)
            ylabel(smdata.channels(getch(dispchan)).name);
        end
    end
end  

x = zeros(1, nloops);
configvals = cell2mat(smget(smdata.configch));
configch = {smdata.channels(smchanlookup(smdata.configch)).name};

configdata = cell(1, length(smdata.configfn));
for i = 1:length(smdata.configfn)
    if iscell(smdata.configfn)
        configdata{i} = smdata.configfn{i}();
    else
        configdata{i} = smdata.configfn(i).fn(smdata.configfn(i).args);   
    end
end

if nargin >= 2
    save(filename, 'configvals', 'configdata', 'scan', 'configch');
    str = [configch; num2cell(configvals)];
    logentry(filename);
    logadd(sprintf('%s=%.3g, ', str{:}));
end

tic;

count = ones(size(npoints)); % will cause all loops to be updated.

% find loops that do nothing other than starting a ramp and have skipping enabled (waittime < 0)
%they also hve no getchan, prefn, postfn, no saves or disps. 
isdummy = false(1, nloops);
for i = 1:nloops
    isdummy(i) = isfield(scandef(i), 'waittime') && ~isempty(scandef(i).waittime) && scandef(i).waittime < 0 ...
        && all(scandef(i).ramptime < 0) && isempty(scandef(i).getchan) ...
        &&  (~isfield(scandef(i), 'prefn') || isempty(scandef(i).prefn)) ...
        && (~isfield(scandef(i), 'postfn') || isempty(scandef(i).postfn)) ...
        && ~any(scan.saveloop(1) == j) && ~any([disp.loop] == j);
end

for i = 1:totpoints    
    % We update outer loops after setting inner loops to 1. 
    % loops is the list to update on this ind. 
    if i > 1;
        outerUpdatingLoop = find(count > 1,1); 
        setLoops = 1:outerUpdatingLoop;       
    else
        setLoops = 1:nloops; % indices of loops to be updated. 1 = fastest loop
    end
    
    %x is the set of values to set in this ind.
    for j = setLoops
        x(j) = scandef(j).rng(count(j));
    end
    
    xtrans = x;  
    for k = 1:length(scan.trafofn)
        xtrans = trafocall(scan.trafofn(k), xtrans);
    end
    
    activeLoops = setLoops(~isdummy(setLoops) | count(setLoops)==1);
    
    %Go from outerloops in. 
    for j = fliplr(activeLoops)
        % exclude dummy loops with nonzero count
        val = trafocall(scandef(j).trafofn, xtrans, smdata.chanvals);
        
        autochan = scandef(j).ramptime < 0;
        scandef(j).ramptime(autochan) = min(scandef(j).ramptime(autochan));        
        % alternative place to call prefn
        
        % set autochannels and program ramp only at first loop point
        if count(j) == 1 %
            if nsetchan(j) 
                smset(scandef(j).setchan, val(1:nsetchan(j)));
                xEnd = x;
                xEnd(j) = scandef(j).rng(end);
                for k = 1:length(scan.trafofn)
                    xEnd = trafocall(scan.trafofn(k), xEnd);
                end

                valEnd = trafocall(scandef(j).trafofn, xEnd, smdata.chanvals);

                % compute ramp rate for all steps.
                ramprate{j} = abs((valEnd(1:nsetchan(j))-val(1:nsetchan(j))))'...
                    ./(scandef(j).ramptime * (scandef(j).npoints-1));

                % program ramp
                if any(autochan)
                    smset(scandef(j).setchan(autochan), valEnd(autochan), ramprate{j}(autochan));
                end
            end
            tFrstPt(j) = now;
        elseif ~all(autochan)
            smset(scandef(j).setchan(~autochan), val(~autochan), ...
                ramprate{j}(~autochan));            
        end
                
        if isfield(scandef, 'prefn')
            fncall(scandef(j).prefn, xtrans);
        end              
        
        %wait for correct ramptime
        tp=count(j) * max(abs(scandef(j).ramptime)) - (now -tFrstPt(j))*24*3600;        
        pause(tp);  % Pause always waits 10ms
        
        % if the field 'waittime' was in scan.loops(j), then wait that
        % amount of time now
        if isfield(scandef,'waittime')
            pause(scandef(j).waittime)
        end
        
        % trigger after waiting for first point.
        if count(j) == 1 && isfield(scandef, 'trigfn')
            fncall(scandef(j).trigfn);
        end
    end
    
    % read loops from inner to outer.
    %Only read the outerloops if inner loops are at their max. i.e. read at
    %the end of the loop. 
    readLoops = 1:find(count < npoints, 1);
    if isempty(readLoops)
        readLoops = 1:nloops;
    end
    for j = readLoops(~isdummy(readLoops))
        newdata = smget(scandef(j).getchan);
        
        if isfield(scandef, 'postfn')
            fncall(scandef(j).postfn, xtrans);
        end

        dataindPrev = sum(ngetchan(1:j-1));
        for k = 1:length(scandef(j).procfn)  
            if isfield(scandef(j).procfn(k).fn, 'outdata')
                for fn = scandef(j).procfn(k).fn
                    if isempty(fn.outchan)
                        data{dataindPrev + fn.outdata} = fn.fn(newdata{fn.inchan}, data{dataindPrev + fn.indata}, fn.args{:});
                    else
                        [newdata{fn.outchan}, data{dataindPrev + fn.outdata}] = fn.fn(newdata{fn.inchan}, data{dataindPrev + fn.indata}, fn.args{:});
                    end
                end
            else
                for fn = scandef(j).procfn(k).fn
                    if isempty(fn.fn)
                        newdata(fn.outchan) = newdata(fn.inchan); % only permute channels
                    else
                        [newdata{fn.outchan}] = fn.fn(newdata{fn.inchan}, fn.args{:});
                    end
                end
                s.subs = [num2cell(count(end:-1:j)), repmat({':'}, 1, ndim(dataindPrev + k))];
                if isempty(fn)
                    data{dataindPrev + k} = subsasgn(data{dataindPrev + k}, s, newdata{k}); 
                else
                    data{dataindPrev + k} = subsasgn(data{dataindPrev + k}, s, newdata{fn.outchan(1)});
                end
            end
               
        end    
        
        % display data. 
        for k = find([disp.loop] == j) %update everything set to updated this loop
            dispchan = disp(k).channel;  % channel to update. 

            nouterLoops = nloops - dataloop(dispchan) + 1; %outerloops for current getchan
            nLoopsPlotted = nloops + 1 - j + disp(k).dim; % number of loops plotted at once + number of loops data replotted   
            dataCellDim = nouterLoops + ndim(dispchan); % number of loops required to plot all data. 
            underSampInds = dataCellDim - nLoopsPlotted;
            % this is done in the case that we are updating a later loop
            % than we can to display all the data. in this case, select
            % just the first row. 
            
            countDataOrd = fliplr(count); % current indices to to be plotting from outer to inner loop.  
            nInds = min(nloops+1-j,nloops+1-j+underSampInds);  % if we underSamp < 0, will need to get total length of s.subs correct.
            s.subs = [num2cell([countDataOrd(1:nInds), ones(1, max(0,underSampInds))]),...
                repmat({':'},1, disp(k).dim)];    
            
            if disp(k).dim == 2
                dataCellSize = size(data{dispchan});
                z = zeros(dataCellSize(end-1:end));
                z(:, :) = subsref(data{dispchan}, s);
                set(disph(k), 'CData', z);
            else                
                set(disph(k), 'YData', subsref(data{dispchan}, s));
            end
            drawnow;
        end

        if j == scan.saveloop(1) && ~mod(count(j), scan.saveloop(2)) && nargin >= 2
            save(filename, '-append', 'data');
        end
               
        if isfield(scandef, 'datafn')
            fncall(scandef(j).datafn, xtrans, data);
        end

    end
    
    %update counters
     if isfield(scandef, 'testfn') && ~isempty(scandef(j).testfn)
            [quitScan,quitLoop,scandef] = fncall(scandef(j).testfn, xt, data, scandef);
     end
   
    count(readLoops(1:end-1)) = 1;
    count(readLoops(end)) =  count(readLoops(end)) + 1;

    %if escape has been typed, exit scan by running cleanup function and
    %saving data. 
    if get(figurenumber, 'CurrentCharacter') == char(27) 
        if isfield(scan, 'cleanupfn')
            for k = 1:length(scan.cleanupfn)
                scan = scan.cleanupfn(k).fn(scan, scan.cleanupfn(k).args{:});
            end
        end
        
        if nargin >= 2
            save(filename, 'configvals', 'configdata', 'scan', 'configch', 'data')
        end
        set(figurenumber, 'CurrentCharacter', char(0));
        set(figurenumber,'userdata',[]); % tag this figure as not being used by SM
        return;
    end
        
    if get(figurenumber, 'CurrentCharacter') == ' '
        set(figurenumber, 'CurrentCharacter', char(0));
        fprintf('Measurement paused. Type ''return'' to continue.\n')
        evalin('base', 'keyboard');                
    end
end

if isfield(scan, 'cleanupfn')
    for k = 1:length(scan.cleanupfn)
        scan = scan.cleanupfn(k).fn(scan, scan.cleanupfn(k).args{:});
    end
end
set(figurenumber,'userdata',[]); % tag this figure as not being used by SM

if nargin >= 2
    save(filename, 'configvals', 'configdata', 'scan', 'configch', 'data')
end
end

function fncall(fns, varargin)   
if iscell(fns)
    for i = 1:length(fns)
        if ischar(fns{i})
          fns{i} = str2func(fns{i});
        end
        fns{i}(varargin{:});
    end
else
    for i = 1:length(fns)
        if ischar(fns(i).fn)
          fns(i).fn = str2func(fns(i).fn);
        end
        fns(i).fn(varargin{:}, fns(i).args{:});        
    end
end
end

function v = trafocall(fn, x, chanvals)   
v = zeros(1, length(fn));
if iscell(fn)
    for i = 1:length(fn)
        if ischar(fn{i})
          fn{i} = str2func(fn{i});
        end
        v(i) = fn{i}(x,chanvals);
    end
else
    for i = 1:length(fn)
        if ischar(fn(i).fn)
          fn(i).fn = str2func(fn(i).fn);
        end
        v(i) = fn(i).fn(x,chanvals, fn(i).args{:});
    end
end
end
