#pragma once

// Minimal stand-in for the ATL string conversions CW2A and CA2W, used only
// when the Visual Studio ATL component is not installed (see
// windows/CMakeLists.txt). Like ATL, the default code page is the thread's
// ANSI code page and a null input converts to null.

#include <windows.h>

#include <string>

class CW2A {
 public:
  CW2A(const wchar_t* psz, UINT nCodePage = CP_THREAD_ACP) {
    if (!psz) return;
    int len = WideCharToMultiByte(nCodePage, 0, psz, -1, nullptr, 0, nullptr,
                                  nullptr);
    if (len > 0) {
      m_str.resize(len);
      WideCharToMultiByte(nCodePage, 0, psz, -1, &m_str[0], len, nullptr,
                          nullptr);
      m_psz = &m_str[0];
    }
  }
  CW2A(const CW2A& other) : m_str(other.m_str) {
    if (other.m_psz) m_psz = &m_str[0];
  }
  CW2A& operator=(const CW2A& other) {
    if (this != &other) {
      m_str = other.m_str;
      m_psz = other.m_psz ? &m_str[0] : nullptr;
    }
    return *this;
  }
  operator LPSTR() const { return m_psz; }

 private:
  std::string m_str;

 public:
  LPSTR m_psz = nullptr;
};

class CA2W {
 public:
  CA2W(const char* psz, UINT nCodePage = CP_THREAD_ACP) {
    if (!psz) return;
    int len = MultiByteToWideChar(nCodePage, 0, psz, -1, nullptr, 0);
    if (len > 0) {
      m_wstr.resize(len);
      MultiByteToWideChar(nCodePage, 0, psz, -1, &m_wstr[0], len);
      m_psz = &m_wstr[0];
    }
  }
  CA2W(const CA2W& other) : m_wstr(other.m_wstr) {
    if (other.m_psz) m_psz = &m_wstr[0];
  }
  CA2W& operator=(const CA2W& other) {
    if (this != &other) {
      m_wstr = other.m_wstr;
      m_psz = other.m_psz ? &m_wstr[0] : nullptr;
    }
    return *this;
  }
  operator LPWSTR() const { return m_psz; }

 private:
  std::wstring m_wstr;

 public:
  LPWSTR m_psz = nullptr;
};
