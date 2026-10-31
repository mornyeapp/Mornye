#pragma once

#include <windows.h>
#include <string>
#include <vector>

// Lightweight ATL string conversion shim for environments without Microsoft.VisualStudio.Component.VC.ATL
class CW2A {
public:
    LPSTR m_psz;

    CW2A(const wchar_t* psz, UINT nCodePage = CP_ACP) : m_psz(nullptr) {
        if (!psz) return;
        int len = WideCharToMultiByte(nCodePage, 0, psz, -1, nullptr, 0, nullptr, nullptr);
        if (len > 0) {
            m_str.resize(len);
            WideCharToMultiByte(nCodePage, 0, psz, -1, &m_str[0], len, nullptr, nullptr);
            m_psz = &m_str[0];
        }
    }
    CW2A(const CW2A& other) : m_str(other.m_str), m_psz(nullptr) {
        if (!m_str.empty()) m_psz = &m_str[0];
    }
    CW2A& operator=(const CW2A& other) {
        if (this != &other) {
            m_str = other.m_str;
            m_psz = m_str.empty() ? nullptr : &m_str[0];
        }
        return *this;
    }
    operator const char*() const { return m_psz ? m_psz : ""; }
    operator char*() { return m_psz ? m_psz : const_cast<char*>(""); }
private:
    std::string m_str;
};

class CA2W {
public:
    LPWSTR m_psz;

    CA2W(const char* psz, UINT nCodePage = CP_ACP) : m_psz(nullptr) {
        if (!psz) return;
        int len = MultiByteToWideChar(nCodePage, 0, psz, -1, nullptr, 0);
        if (len > 0) {
            m_wstr.resize(len);
            MultiByteToWideChar(nCodePage, 0, psz, -1, &m_wstr[0], len);
            m_psz = &m_wstr[0];
        }
    }
    CA2W(const CA2W& other) : m_wstr(other.m_wstr), m_psz(nullptr) {
        if (!m_wstr.empty()) m_psz = &m_wstr[0];
    }
    CA2W& operator=(const CA2W& other) {
        if (this != &other) {
            m_wstr = other.m_wstr;
            m_psz = m_wstr.empty() ? nullptr : &m_wstr[0];
        }
        return *this;
    }
    operator const wchar_t*() const { return m_psz ? m_psz : L""; }
    operator wchar_t*() { return m_psz ? m_psz : const_cast<wchar_t*>(L""); }
private:
    std::wstring m_wstr;
};
