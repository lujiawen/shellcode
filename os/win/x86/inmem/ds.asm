;
;  Copyright © 2019 Odzhan. All Rights Reserved.
;
;  Redistribution and use in source and binary forms, with or without
;  modification, are permitted provided that the following conditions are
;  met:
;
;  1. Redistributions of source code must retain the above copyright
;  notice, this list of conditions and the following disclaimer.
;
;  2. Redistributions in binary form must reproduce the above copyright
;  notice, this list of conditions and the following disclaimer in the
;  documentation and/or other materials provided with the distribution.
;
;  3. The name of the author may not be used to endorse or promote products
;  derived from this software without specific prior written permission.
;
;  THIS SOFTWARE IS PROVIDED BY AUTHORS "AS IS" AND ANY EXPRESS OR
;  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
;  DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
;  INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
;  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
;  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
;  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
;  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
;  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;  POSSIBILITY OF SUCH DAMAGE.
;

; DLL loader in 311 bytes of x86 assembly (written for fun)
; odzhan

      %include "ds.inc"

      bits   32

      struc _ds
          .VirtualAlloc        resd 1 ; edi
          .LoadLibraryA        resd 1 ; esi
          .GetProcAddress      resd 1 ; ebp
          .AddressOfEntryPoint resd 1 ; ebx
          .ImportTable         resd 1 ; edx
          .BaseRelocationTable resd 1 ; eax
          .ImageBase           resd 1 ; ecx
      endstruc

      %ifndef BIN
        global load_dllx
        global _load_dllx
      %endif
      
load_dllx:
_load_dllx: 
      pop    eax            ; eax = return address
      pop    ebx            ; ebx = base of PE file
      push   eax            ; save return address on stack
      pushad                ; save all registers
      call   init_api       ; load address of api hash onto stack
      dd     0x38194E37     ; VirtualAlloc
      dd     0xFA183D4A     ; LoadLibraryA
      dd     0x4AAC90F7     ; GetProcAddress
init_api:
      pop    esi            ; esi = api hashes
      pushad                ; allocate 32 bytes of memory for _ds
      mov    edi, esp       ; edi = _ds
      push   3              ; resolve three api
      pop    ecx
get_apis:
      lodsd                 ; eax = hash
      pushad
      mov    cl, TEB.ProcessEnvironmentBlock
      mov    eax, [fs:ecx]
      mov    eax, [eax+PEB.Ldr]
      mov    edi, [eax+PEB_LDR_DATA.InLoadOrderModuleList + LIST_ENTRY.Flink]
      jmp    get_dll
next_dll:    
      mov    edi, [edi+LDR_DATA_TABLE_ENTRY.InLoadOrderLinks + LIST_ENTRY.Flink]
get_dll:
      mov    ebx, [edi+LDR_DATA_TABLE_ENTRY.DllBase]
      mov    eax, [ebx+IMAGE_DOS_HEADER.e_lfanew]
      ; ecx = IMAGE_DATA_DIRECTORY.VirtualAddress
      mov    ecx, [ebx+eax+IMAGE_NT_HEADERS.OptionalHeader + \
                           IMAGE_OPTIONAL_HEADER32.DataDirectory + \
                           IMAGE_DIRECTORY_ENTRY_EXPORT * IMAGE_DATA_DIRECTORY_size + \
                           IMAGE_DATA_DIRECTORY.VirtualAddress]
      jecxz  next_dll      
      ; esi = offset IMAGE_EXPORT_DIRECTORY.NumberOfNames 
      lea    esi, [ebx+ecx+IMAGE_EXPORT_DIRECTORY.NumberOfNames]
      lodsd
      xchg   eax, ecx
      jecxz  next_dll        ; skip if no names
      push   edi             ; save edi
      ; save IMAGE_EXPORT_DIRECTORY.AddressOfFunctions     
      lodsd
      add    eax, ebx        ; eax = RVA2VA(eax, ebx)
      push   eax             ; save address of functions
      ; edi = IMAGE_EXPORT_DIRECTORY.AddressOfNames
      lodsd
      add    eax, ebx        ; eax = RVA2VA(eax, ebx)
      xchg   eax, edi        ; swap(eax, edi)
      ; save IMAGE_EXPORT_DIRECTORY.AddressOfNameOrdinals
      lodsd
      add    eax, ebx        ; eax = RVA(eax, ebx)
      push   eax             ; save address of name ordinals
get_name:
      mov    esi, [edi+ecx*4-4] ; esi = RVA of API string
      add    esi, ebx           ; esi = RVA2VA(esi, ebx)
      xor    eax, eax           ; zero eax
      cdq                       ; h = 0
hash_name:    
      lodsb
      add    edx, eax
      ror    edx, 8
      dec    eax
      jns    hash_name
      cmp    edx, [esp+_eax+3*4]   ; hashes match?
      loopne get_name              ; --ecx && edx != hash
      pop    edx                   ; edx = AddressOfNameOrdinals
      pop    esi                   ; esi = AddressOfFunctions
      pop    edi                   ; restore DLL entry
      jne    next_dll              ; get next DLL        
      movzx  eax, word [edx+ecx*2] ; eax = AddressOfNameOrdinals[eax]
      add    ebx, [esi+eax*4]      ; ecx = base + AddressOfFunctions[eax]
      mov    [esp+_eax], ebx
      popad                        ; restore all
      stosd
      loop   get_apis
      mov    cl, (MEM_RESERVE | MEM_COMMIT) >> 8
      ; dos = (PIMAGE_DOS_HEADER)ebx
      push   ebx
      add    ebx, [ebx+IMAGE_DOS_HEADER.e_lfanew]
      add    ebx, ecx
      ; esi = &nt->OptionalHeader.AddressOfEntryPoint
      lea    esi, [ebx+IMAGE_NT_HEADERS.OptionalHeader + \
                       IMAGE_OPTIONAL_HEADER32.AddressOfEntryPoint - 30h]
      movsd          ; [edi+ 0] = AddressOfEntryPoint
      mov    eax, [ebx+IMAGE_NT_HEADERS.OptionalHeader + \
                       IMAGE_OPTIONAL_HEADER32.DataDirectory + \
                       IMAGE_DIRECTORY_ENTRY_IMPORT * IMAGE_DATA_DIRECTORY_size + \
                       IMAGE_DATA_DIRECTORY.VirtualAddress - 30h]
      stosd          ; [edi+ 4] = Import Directory Table RVA
      mov    eax, [ebx+IMAGE_NT_HEADERS.OptionalHeader + \
                       IMAGE_OPTIONAL_HEADER32.DataDirectory + \
                       IMAGE_DIRECTORY_ENTRY_BASERELOC * IMAGE_DATA_DIRECTORY_size + \
                       IMAGE_DATA_DIRECTORY.VirtualAddress - 30h]
      stosd          ; [edi+ 8] = Base Relocation Table RVA
      lodsd          ; skip BaseOfCode
      lodsd          ; skip BaseOfData
      movsd          ; [edi+12] = ImageBase
      ; cs  = VirtualAlloc(NULL, nt->OptionalHeader.SizeOfImage, 
      ;          MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
      push   PAGE_EXECUTE_READWRITE
      xchg   cl, ch
      push   ecx
      push   dword[esi + IMAGE_OPTIONAL_HEADER32.SizeOfImage - \
                         IMAGE_OPTIONAL_HEADER32.SectionAlignment]
      push   0                           ; NULL
      call   dword[esp + _ds.VirtualAlloc + 5*4]
      xchg   eax, edi                    ; edi = cs
      pop    esi                         ; esi = base
      
      ; load number of sections
      movzx  ecx, word[ebx + IMAGE_NT_HEADERS.FileHeader + \
                             IMAGE_FILE_HEADER.NumberOfSections - 30h]
      ; edx = IMAGE_FIRST_SECTION()
      movzx  eax, word[ebx + IMAGE_NT_HEADERS.FileHeader + \
                             IMAGE_FILE_HEADER.SizeOfOptionalHeader - 30h]
      lea    edx, [ebx + eax + IMAGE_NT_HEADERS.OptionalHeader - 30h]
map_section:
      pushad
      add    edi, [edx + IMAGE_SECTION_HEADER.VirtualAddress]
      add    esi, [edx + IMAGE_SECTION_HEADER.PointerToRawData]
      mov    ecx, [edx + IMAGE_SECTION_HEADER.SizeOfRawData]
      rep    movsb
      popad
      add    edx, IMAGE_SECTION_HEADER_size
      loop   map_section
      mov    ebx, edi
      ; process the import table
      pushad
      mov    ecx, [esp + _ds.ImportTable + pushad_t_size]
      jecxz  imp_l2
      lea    ebp, [ecx + ebx]
imp_l0:
      mov    esi, ebp
      lodsd                   ; OriginalFirstThunk +00h
      xchg   eax, edi         ; temporarily store in edi
      lodsd                   ; TimeDateStamp      +04h
      lodsd                   ; ForwarderChain     +08h
      lodsd                   ; Name               +0Ch
      xchg   eax, ecx
      jecxz  imp_l2
      add    ecx, ebx         ; name = RVA2VA(PCHAR, cs, imp->Name);
      ; dll = LoadLibrary(name);
      push   ecx
      call   dword[esp + _ds.LoadLibraryA + 4 + pushad_t_size]  
      xchg   edx, eax         ; edx = dll
      lodsd                   ; eax = imp->FirstThunk
      mov    ebp, esi
      ; oft = RVA2VA(PIMAGE_THUNK_DATA, cs, imp->OriginalFirstThunk);
      lea    esi, [edi + ebx]
      ; ft  = RVA2VA(PIMAGE_THUNK_DATA, cs, imp->FirstThunk);
      lea    edi, [eax + ebx]
imp_l1:
      lodsd                   ; eax = oft->u1.AddressOfData, oft++;
      xchg   eax, ecx
      jecxz  imp_l0           ; if (oft->u1.AddressOfData == 0) break; 
      btr    ecx, 31
      jc     imp_Lx           ; IMAGE_SNAP_BY_ORDINAL(oft->u1.Ordinal)
      ; RVA2VA(PIMAGE_IMPORT_BY_NAME, cs, oft->u1.AddressOfData)
      lea    ecx, [ecx + ebx + IMAGE_IMPORT_BY_NAME.Name]
imp_Lx:
      ; eax = GetProcAddress(dll, ecx);
      push   edx
      push   ecx
      push   edx
      call   dword[esp + _ds.GetProcAddress + 3*4 + pushad_t_size]  
      pop    edx
      stosd                   ; ft->u1.Function = eax
      jmp    imp_l1
imp_l2:
      popad
      ; ibr  = RVA2VA(PIMAGE_BASE_RELOCATION, cs, dir[IMAGE_DIRECTORY_ENTRY_BASERELOC].VirtualAddress);
      mov    esi, [esp + _ds.BaseRelocationTable]
      add    esi, ebx
      ; ofs  = (PBYTE)cs - opt->ImageBase;
      mov    ebp, ebx
      sub    ebp, [esp + _ds.ImageBase]
reloc_L0:
      ; while (ibr->VirtualAddress != 0) {
      lodsd                  ; eax = ibr->VirtualAddress
      xchg   eax, ecx
      jecxz  call_entrypoint
      lodsd                  ; skip ibr->SizeOfBlock
      lea    edi, [esi + eax - 8]
reloc_L1:
      lodsw                  ; ax = *(WORD*)list;
      and    eax, 0xFFF      ; eax = list->offset
      jz     reloc_L2        ; IMAGE_REL_BASED_ABSOLUTE is used for padding
      add    eax, ecx        ; eax += ibr->VirtualAddress
      add    eax, ebx        ; eax += cs
      add    [eax], ebp      ; *(DWORD*)eax += ofs
      ; ibr = (PIMAGE_BASE_RELOCATION)list;
reloc_L2:
      ; (PBYTE)list != (PBYTE)ibr + ibr->SizeOfBlock
      cmp    esi, edi
      jne    reloc_L1
      jmp    reloc_L0
call_entrypoint:
      push   ecx                 ; lpvReserved
      push   DLL_PROCESS_ATTACH  ; fdwReason    
      push   ebx                 ; HINSTANCE   
      ; DllMain = RVA2VA(entry_exe, cs, opt->AddressOfEntryPoint);
      add    ebx, [esp + _ds.AddressOfEntryPoint]
      call   ebx
      popad                  ; release _ds
      popad                  ; restore registers
      ret
      